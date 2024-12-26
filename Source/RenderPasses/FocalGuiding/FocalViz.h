#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"

#include "DensityNode.h"

using namespace Falcor;

#define VIZ_COLORS_COUNT 7


class FocalViz : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(FocalViz, "FocalViz", "Insert pass description here.");

    static ref<FocalViz> create(ref<Device> pDevice, const Properties& props) { return make_ref<FocalViz>(pDevice, props); }

    FocalViz(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

    enum class VizColorPalette : uint32_t
    {
        YellowToRed,
        Viridis,
        Inferno,
        Magma,
        Plasma
    };

    FALCOR_ENUM_INFO(
        VizColorPalette,
        {
            {VizColorPalette::YellowToRed, "YellowToRed"},
            {VizColorPalette::Viridis, "Viridis"},
            {VizColorPalette::Inferno, "Inferno"},
            {VizColorPalette::Magma, "Magma"},
            {VizColorPalette::Plasma, "Plasma"},
        }
    );

    enum class DensityAccType : uint32_t
    {
        Max,
        Avg
    };

    FALCOR_ENUM_INFO(
        DensityAccType,
        {
            {DensityAccType::Max, "Max"},
            {DensityAccType::Avg, "Avg"},
        }
    );

private:
    void parseProperties(const Properties& props);
    void prepareVars();

    float3 rgb(int r, int g, int b);
    void setColors();
    void setYellowToRedColors();

    // Internal state
    ref<Scene> mpScene; ///< Current scene.
    ref<Buffer> mNodes;
    ref<Buffer> mGlobalAccumulator;
    ref<ParameterBlock> mpNodesBlock;

    uint mNodesSize = 1;
    uint mMaxNodesSize = 1;
    uint mMaxOctreeDepth = 3;

    uint mFrameCount = 0;
    uint mMaxSliderDensity = 8;
    float mMinDensity = 0.0f;
    float mMaxDensity = 1.0f;
    
    std::array<float3, VIZ_COLORS_COUNT> mVizColors;
    VizColorPalette mColorPalette = VizColorPalette::Inferno;
    DensityAccType mDensityAccType = DensityAccType::Max;
    bool mBlendFromScene = true;
    float mMinBlendAlpha = 0.95f;
    bool mNormalsViz = false;

    bool mOptionsChanged = false;

    // Ray tracing program.
    struct
    {
        ref<Program> pProgram;
        ref<RtBindingTable> pBindingTable;
        ref<RtProgramVars> pVars;
    } mTracer;
};

FALCOR_ENUM_REGISTER(FocalViz::VizColorPalette);
FALCOR_ENUM_REGISTER(FocalViz::DensityAccType);
