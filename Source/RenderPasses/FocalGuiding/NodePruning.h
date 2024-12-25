#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "RenderGraph/RenderPassHelpers.h"

#include "DensityNode.h"

using namespace Falcor;

class NodePruning : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(NodePruning, "NodePruning", "");

    static ref<NodePruning> create(ref<Device> pDevice, const Properties& props) { return make_ref<NodePruning>(pDevice, props); }

    NodePruning(ref<Device> pDevice, const Properties& props);

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
    ref<Buffer> mGlobalAccumulator;
    ref<ParameterBlock> mpNodesBlock;

    uint mNodesSize = 1;
    uint mMaxNodesSize = 1;
    ref<Buffer> mNodesSizeBuffer;
    ref<Buffer> mMaxDensitiesBuffer;
    ref<Buffer> mAvgDensitiesBuffer;
    uint mMaxOctreeDepth = 3;

    bool mUsePruning = true;
    bool mRunAfterLastIter = true;
    uint mRunInFrame = 6;

    uint mPassCount = 0;

    ref<Program> mpProgram;
    ref<ProgramVars> mpVars;
    ref<ComputeState> mpState;
};
