#!/usr/bin/env python3
"""Run one command with a hard deadline and terminate its whole process group."""

import os
import signal
import subprocess
import sys
import time
from typing import List


def process_group_exists(process_group_id: int) -> bool:
    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_for_group_exit(
    process: subprocess.Popen, process_group_id: int, timeout_seconds: float
) -> bool:
    deadline = time.monotonic() + max(0.0, timeout_seconds)
    while True:
        process.poll()
        if not process_group_exists(process_group_id):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)


def terminate_group(process: subprocess.Popen, grace_seconds: float = 2.0) -> bool:
    process_group_id = process.pid
    try:
        os.killpg(process_group_id, signal.SIGTERM)
    except ProcessLookupError:
        process.poll()
        return True
    if wait_for_group_exit(process, process_group_id, grace_seconds):
        return True
    try:
        os.killpg(process_group_id, signal.SIGKILL)
    except ProcessLookupError:
        process.poll()
        return True
    return wait_for_group_exit(process, process_group_id, grace_seconds)


def main(arguments: List[str]) -> int:
    if len(arguments) < 2:
        print("usage: tts-run-with-timeout.py seconds -- command [args...]", file=sys.stderr)
        return 2
    try:
        timeout_seconds = float(arguments[0])
    except ValueError:
        print("timeout must be numeric", file=sys.stderr)
        return 2
    if timeout_seconds <= 0:
        print("timeout must be greater than zero", file=sys.stderr)
        return 2
    command = arguments[1:]
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        print("missing command", file=sys.stderr)
        return 2

    handled_signals = (signal.SIGINT, signal.SIGTERM)
    pending_signals = []

    def defer_signal_until_spawned(signum, _frame):
        if not pending_signals:
            pending_signals.append(signum)

    previous_handlers = {}
    for signum in handled_signals:
        previous_handlers[signum] = signal.signal(signum, defer_signal_until_spawned)
    try:
        process = subprocess.Popen(command, start_new_session=True)

        def terminate_on_signal(signum, _frame):
            for handled_signal in handled_signals:
                signal.signal(handled_signal, signal.SIG_IGN)
            signal_name = signal.Signals(signum).name
            print(
                f"Received {signal_name}; terminating the wrapped TTS process group.",
                file=sys.stderr,
            )
            if not terminate_group(process):
                print(
                    "Wrapped TTS process group did not exit after TERM/KILL escalation.",
                    file=sys.stderr,
                )
            raise SystemExit(128 + signum)

        for signum in handled_signals:
            signal.signal(signum, terminate_on_signal)
        if pending_signals:
            terminate_on_signal(pending_signals[0], None)

        try:
            status = process.wait(timeout=timeout_seconds)
            if process_group_exists(process.pid):
                print(
                    "Wrapped TTS command exited with descendant processes still running; terminating its process group.",
                    file=sys.stderr,
                )
                if not terminate_group(process):
                    print(
                        "Wrapped TTS descendant process group did not exit after TERM/KILL escalation.",
                        file=sys.stderr,
                    )
            return status
        except subprocess.TimeoutExpired:
            print(
                f"Wrapped TTS command exceeded {timeout_seconds:g} seconds; terminating it.",
                file=sys.stderr,
            )
            terminate_group(process)
            return 124
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
