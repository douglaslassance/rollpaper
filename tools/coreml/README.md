# RealESRGANx4v3 Core ML model

`Sources/App/Resources/RealESRGANx4v3.mlmodelc` is Real-ESRGAN's
`realesr-general-x4v3` (SRVGGNetCompact, 4× super-resolution) converted to a
Core ML program (fp16). License: BSD-3-Clause, © Xintao Wang et al.

## Regenerate

```sh
cd tools/coreml
curl -sL -o realesr-general-x4v3.pth \
  https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth
uv run --python 3.11 --with torch --with coremltools --with 'numpy<2' python convert.py
xcrun coremlc compile RealESRGANx4v3.mlpackage .
cp -R RealESRGANx4v3.mlmodelc ../../Sources/App/Resources/
```

The model has a fixed 256×256 input; the app tiles larger images (see
`CoreMLUpscaler`). Attribution must ship with the app (About screen).
