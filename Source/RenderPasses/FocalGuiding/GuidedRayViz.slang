import Scene.Raster; // Imports defaultVS.

cbuffer PerFrameCB
{
    float4 gColor;
    bool gShadedLines;
    bool gUseIntensity;
};

VSOut vsMain(VSIn vIn)
{
    return defaultVS(vIn);
}

float4 psMain(VSOut pIn) : SV_TARGET
{
    float4 outColor = gColor;
    if (gUseIntensity)
    {
        float intensity = pIn.texC.x;
        outColor = float4(outColor.xyz * intensity, outColor.w);
    }
    if (gShadedLines)
    {
        float3 rgb = outColor.xyz * clamp(dot(pIn.normalW, float3(0, 1, 0)), 0.2, 1.0);
        outColor = float4(rgb, outColor.w);
    }
    return outColor;
}
