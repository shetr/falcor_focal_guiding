#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"

using namespace Falcor;

class GuidedRayViz : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(GuidedRayViz, "GuidedRayViz", "Insert pass description here.");

    static ref<GuidedRayViz> create(ref<Device> pDevice, const Properties& props) { return make_ref<GuidedRayViz>(pDevice, props); }

    GuidedRayViz(ref<Device> pDevice, const Properties& props);

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

    ref<Buffer> mNodes;

    uint mNodesSize = 1;
    uint mMaxOctreeDepth = 3;

    // Internal state
    ref<Scene> mpScene;
};
