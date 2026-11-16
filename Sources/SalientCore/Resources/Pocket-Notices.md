# Pocket TTS acknowledgments

Salient uses Kyutai Pocket TTS 4.0.1 (MIT), adapted into a native Rust worker
using xn-ptts and xn. The English October 2026 stock model and the Alba voice,
acted by Alba MacKenna, are CC BY 4.0. The checkpoint and voice embedding are
unmodified downloads; optional runtime int8 quantization changes the in-memory
representation. Synthesized speech is generated content.

- Code: https://github.com/kyutai-labs/pocket-tts/tree/v4.0.1/rust
- Model: https://huggingface.co/kyutai/pocket-tts-without-voice-cloning
- Voice attribution: https://huggingface.co/kyutai/tts-voices#alba-mackenna
- Attribution license: https://creativecommons.org/licenses/by/4.0/
- Inference: https://github.com/gabrieldemarmiesse/xn-ptts/tree/7efa26973f81bba42cf2ace8da2c1eb9b605d54d
- Tensor engine: https://github.com/LaurentMazare/xn

The app bundles the native worker, the English stock model, the Alba voice,
and dependency notices (Pocket Runtime Notices.txt). Pocket needs no Python,
PyTorch, uv, Homebrew, model account, local HTTP server, extra download,
or network connection, including on first launch.
The default does not redistribute a gated cloning model, Hugging Face token,
or private/custom reference sample. Keep these attributions with the app and
redistributed model assets.

Pocket TTS code license (MIT):

Permission is hereby granted, free of charge, to any
person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the
Software without restriction, including without
limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice
shall be included in all copies or substantial portions
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
