import torch, torch.nn as nn, torch.nn.functional as F
import coremltools as ct
import numpy as np

class SRVGGNetCompact(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(nn.PReLU(num_parameters=num_feat))
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)
    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        base = F.interpolate(x, scale_factor=self.upscale, mode='nearest')
        return out + base

net = SRVGGNetCompact()
sd = torch.load("realesr-general-x4v3.pth", map_location="cpu")
sd = sd.get("params", sd)
net.load_state_dict(sd, strict=True)
net.eval()
print("✅ weights loaded (strict)")

TILE = 256
ex = torch.rand(1,3,TILE,TILE)
traced = torch.jit.trace(net, ex)

mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=(1,3,TILE,TILE), scale=1/255.0, color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="output")],
    minimum_deployment_target=ct.target.macOS14,
    compute_precision=ct.precision.FLOAT16,
    convert_to="mlprogram",
)
mlmodel.short_description = "Real-ESRGAN realesr-general-x4v3 (SRVGGNetCompact, 4x). BSD-3-Clause, Xintao Wang et al."
out = "RealESRGANx4v3.mlpackage"
mlmodel.save(out)
print("✅ saved", out)
