#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"

#include "DensityNode.h"

using namespace Falcor;

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

private:
    void prepareVars();

    // Internal state
    ref<Scene> mpScene; ///< Current scene.
    ref<Buffer> mNodes;
    ref<ParameterBlock> mpNodesBlock;

    uint mNodesSize = 1;
    uint mMaxOctreeDepth = 3;

    uint mFrameCount = 0;
    uint mMaxSliderDensity = 1000;
    float mMinDensity = 0.0f;
    float mMaxDensity = 1.0f;
    bool mOptionsChanged = false;

    // Ray tracing program.
    struct
    {
        ref<Program> pProgram;
        ref<RtBindingTable> pBindingTable;
        ref<RtProgramVars> pVars;
    } mTracer;
};
