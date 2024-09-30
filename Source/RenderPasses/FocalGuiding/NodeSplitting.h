#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "RenderGraph/RenderPassHelpers.h"

#include "DensityNode.h"

using namespace Falcor;

class NodeSplitting : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(NodeSplitting, "NodeSplitting", "Insert pass description here.");

    static ref<NodeSplitting> create(ref<Device> pDevice, const Properties& props) { return make_ref<NodeSplitting>(pDevice, props); }

    NodeSplitting(ref<Device> pDevice, const Properties& props);

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
    ref<Scene> mpScene;                     ///< Current scene.
    ref<Buffer> mNodes;
    ref<ParameterBlock> mpNodesBlock;

    uint mNodesSize = 1;
    uint mMaxNodesSize = 1;
    ref<Buffer> mNodesSizeBuffer;
    uint mMaxOctreeDepth = 3;

    float mSplittingThreshold = 0.001f;
    //float mSplittingThreshold = 0.0f;
    bool mLimitedPasses = true;
    uint mMaxPassCount = 5;

    uint mPassCount = 0;

    ref<Program> mpProgram;
    ref<ProgramVars> mpVars;
    ref<ComputeState> mpState;
};
