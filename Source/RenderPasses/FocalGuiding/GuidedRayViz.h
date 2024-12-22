#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "Scene/SceneBuilder.h"

#include "GuidedRayLine.h"

using namespace Falcor;

class GuidedRayViz : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(GuidedRayViz, "GuidedRayViz", "ray vizulalisation");

    static ref<GuidedRayViz> create(ref<Device> pDevice, const Properties& props) { return make_ref<GuidedRayViz>(pDevice, props); }

    GuidedRayViz(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override;
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override;

private:
    void prepareVars();
    void generateRaysGeometry(uint linesPathLenght);
    void createLine(SceneBuilder::ProcessedMesh& mesh, GuidedRayLine rayLine, int& index);
    void createTube(SceneBuilder::ProcessedMesh& mesh, GuidedRayLine rayLine, float maxIntensity, int& index, bool scaleLength);
    void createQuad(
        SceneBuilder::ProcessedMesh& mesh,
        int& index,
        float intensity,
        float3 x11, float3 x12, float3 x21, float3 x22, float3 n11, float3 n12, float3 n21, float3 n22
    );
    float3 getPerpendicualrTo(float3 dir);
    float colorToIntensity(float3 color);

    uint mMaxGuidedRaysSize = 1000;
    uint mGuidedRaysSize = 500;
    float mLineLengthScale = 0.25;
    float mLineWidthScale = 0.5;
    ref<Buffer> mGuidedRays;
    bool mComputeRays = true;
    float4 mLinesColor = float4(1, 1, 0, 1);
    float mMinIntensity = 0.03f;
    bool mUseIntensity = false;
    bool mShadedLines = false;
    bool mShiftPressed = false;

    // Internal state
    ref<Scene> mpScene;

    ref<Scene> mpRayScene;
    MeshID mLinesMeshId;
    NodeID mLinesNodeId;

    ref<Program> mpProgram;
    ref<GraphicsState> mpGraphicsState;
    ref<RasterizerState> mpRasterState;
    ref<BlendState> mpBlendState;
    ref<ProgramVars> mpVars;
};
