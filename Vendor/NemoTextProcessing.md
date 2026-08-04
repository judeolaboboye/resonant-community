# NemoTextProcessing Vendor Notes

Vendored from [FluidInference/text-processing-rs](https://github.com/FluidInference/text-processing-rs) at commit `1b90efaef7585d9f07d0074eb4dd7b5232eb3c3d`.

This package uses the upstream Rust FFI through the local XCFramework at `Vendor/NemoTextProcessing.xcframework`.

To rebuild the XCFramework from upstream, run:

```bash
./scripts/build_nemo_text_processing.sh
```
