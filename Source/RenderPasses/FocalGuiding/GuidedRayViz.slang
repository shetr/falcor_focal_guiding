import Scene.Raster; // Imports defaultVS.

cbuffer PerFrameCB
{
    float4 gColor;
    float gMinIntensity;
    float gLightTheta;
    float gLightPhi;
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
        float intensity = max(gMinIntensity, pIn.texC.x);
        outColor = float4(outColor.xyz * intensity, outColor.w);
    }
    if (gShadedLines)
    {
        float phi = radians(gLightPhi);
        float theta = radians(gLightTheta);
        float sinTheta = sin(theta);
        float3 lightDir = float3(cos(phi) * sinTheta, cos(theta), sin(phi) * sinTheta);
        float3 rgb = outColor.xyz * clamp(dot(pIn.normalW, lightDir), 0.2, 1.0);
        outColor = float4(rgb, outColor.w);
    }
    return outColor;
}
