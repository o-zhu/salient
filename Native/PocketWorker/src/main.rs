//! Offline Pocket TTS v4.0.1, with a bounded private stdin/stdout PCM protocol.
//! Never print source text, write generated audio, open a socket, or read tokens.
#[allow(dead_code)] mod config;
#[allow(dead_code)] mod defaults;
mod download;
mod numbers;
#[allow(dead_code)] mod model;
mod rng;
mod text;
mod tokenizer;
#[allow(dead_code)] mod weights;

use anyhow::{Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use model::{CpuBackend, LoadOptions, TtsModel};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::io::{BufRead, Read, Write};
use std::path::Path;
use std::sync::atomic::AtomicBool;
use std::time::Instant;

const MAX_LINE: u64 = 32768;
const PCM_FRAMES: usize = 1920;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request { id: String, text: String }

fn verify(path: &Path, expected: &str) -> Result<()> {
    let mut file = std::fs::File::open(path)?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 { break; }
        hash.update(&buffer[..n]);
    }
    ensure!(format!("{:x}", hash.finalize()) == expected, "Asset integrity check failed");
    Ok(())
}

fn emit(output: &mut impl Write, value: serde_json::Value) -> Result<()> {
    serde_json::to_writer(&mut *output, &value)?;
    output.write_all(b"\n")?;
    output.flush()?;
    Ok(())
}

fn validate(request: &Request) -> Result<()> {
    ensure!(request.id.len() == 36 && request.id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-'), "Invalid request id");
    ensure!(!request.text.trim().is_empty() && request.text.chars().count() <= 4000, "Invalid text length");
    Ok(())
}

fn serve<Q: CpuBackend>(root: &Path, precision: &str) -> Result<()> {
    let assets = root.join("assets");
    let manifest: serde_json::Value = serde_json::from_str(include_str!("../../../Sources/SalientCore/Resources/pocket-assets.json"))?;
    for asset in manifest["assets"].as_array().unwrap() {
        verify(&assets.join(asset["name"].as_str().unwrap()), asset["sha256"].as_str().unwrap())?;
    }
    let mut config = config::Config::parse(include_str!("../config/english.yaml"))?;
    config.weights_path = Some(assets.join("model.safetensors").to_string_lossy().into_owned());
    config.weights_path_without_voice_cloning = None;
    config.flow_lm.lookup_table.tokenizer_path = assets.join("tokenizer.json").to_string_lossy().into_owned();
    let model = TtsModel::<Q>::load(config, config::Origin::Language("english_2026-10".into()), &LoadOptions::default())?;
    let voice = model.get_state_for_audio_prompt(&assets.join("alba.safetensors").to_string_lossy(), false)?;
    ensure!(model.sample_rate() == 24000, "Invalid sample rate");
    // Stdout rather than StdoutLock is Send, which the concurrent decoder needs.
    let mut output = std::io::stdout();
    emit(&mut output, json!({"type":"ready", "schema":2, "version":"4.0.1", "precision":precision}))?;
    let mut input = std::io::stdin().lock();
    loop {
        let mut line = Vec::new();
        if (&mut input).take(MAX_LINE + 1).read_until(b'\n', &mut line)? == 0 { break; }
        ensure!(line.len() as u64 <= MAX_LINE && line.last() == Some(&b'\n'), "Oversized request");
        let request: Request = serde_json::from_slice(&line)?;
        validate(&request)?;
        let start = Instant::now();
        let mut sequence = 0;
        let mut frames = 0;
        let spoken_text = numbers::prepare(&request.text);
        model.generate_audio_stream(&voice, &spoken_text, 50, None, &AtomicBool::new(false), &mut |samples| {
            for chunk in samples.chunks(PCM_FRAMES) {
                ensure!(chunk.iter().all(|s| s.is_finite()), "Invalid PCM");
                let bytes: Vec<u8> = chunk.iter().flat_map(|s| s.to_le_bytes()).collect();
                emit(&mut output, json!({"type":"chunk", "id":request.id, "sequence":sequence,
                    "frames":chunk.len(), "pcm":STANDARD.encode(bytes), "generationSeconds":start.elapsed().as_secs_f64()}))?;
                sequence += 1;
                frames += chunk.len();
            }
            Ok(())
        })?;
        ensure!(frames > 0, "Empty audio");
        emit(&mut output, json!({"type":"done", "id":request.id, "sequence":sequence,
            "frames":frames, "generationSeconds":start.elapsed().as_secs_f64()}))?;
    }
    Ok(())
}

fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args == ["--version"] {
        println!("salient-pocket-worker 4.0.1 protocol 2");
        return Ok(());
    }
    ensure!(args.len() == 3 && args[0] == "--root", "Invalid arguments");
    let root = Path::new(&args[1]);
    ensure!(root.is_absolute(), "Absolute asset root required");
    match args[2].as_str() {
        "--int8" => serve::<xn::quantized::Q80F32>(root, "int8"),
        "--float32" => serve::<xn::Unquantized<f32, xn::CpuDevice>>(root, "float32"),
        _ => anyhow::bail!("Unsupported precision"),
    }
}

fn main() -> std::process::ExitCode {
    // Dependency errors and panic messages may contain text. Keep them private.
    std::panic::set_hook(Box::new(|_| eprintln!("Pocket worker stopped")));
    match run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(_) => { eprintln!("Pocket worker could not complete the request"); std::process::ExitCode::from(1) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn protocol_rejects_unbounded_or_empty_input() {
        let mut request = Request { id: "12345678-1234-1234-1234-123456789abc".into(), text: "Synthetic test.".into() };
        assert!(validate(&request).is_ok());
        request.text = " ".into(); assert!(validate(&request).is_err());
        request.text = "x".repeat(4001); assert!(validate(&request).is_err());
    }
    #[test]
    fn loader_cannot_download_assets() {
        for source in ["https://example.com/model", "hf://repo/model", "relative/model"] {
            assert!(download::download_if_necessary(source).is_err());
        }
    }
}
