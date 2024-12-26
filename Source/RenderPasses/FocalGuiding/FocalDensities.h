#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"

#include "DensityNode.h"

using namespace Falcor;

class FocalDensities : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(FocalDensities, "FocalDensities", "Insert pass description here.");

    static ref<FocalDensities> create(ref<Device> pDevice, const Properties& props) { return make_ref<FocalDensities>(pDevice, props); }

    FocalDensities(ref<Device> pDevice, const Properties& props);

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

    void printNodes();

    void setUniformNodes();
    std::vector<DensityNode> genUniformNodes(uint depth, bool random) const;
    std::vector<DensityNode> genRandomNodes() const;

    // Internal state
    ref<Scene> mpScene; ///< Current scene.
    ref<SampleGenerator> mpSampleGenerator; ///< GPU sample generator.
    ref<Buffer> mNodes;
    ref<Buffer> mGlobalAccumulator;
    ref<Buffer> mTempNodes;
    ref<Buffer> mTempGlobalAccumulator;
    ref<ParameterBlock> mpNodesBlock;
    ref<ParameterBlock> mpTempNodesBlock;

    uint mMaxBounces = 3;   
    uint mNodesSize = 1;
    uint mMaxNodesSize = 2000;
    uint mInitOctreeDepth = 3;
    uint mMaxOctreeDepth = 5;

    bool mUseRelativeContributions = true;
    bool mPause = false;
    bool mLimitedPasses = true;
    bool mUseNarrowing = true;
    float mNarrowFactor = 1.0;
    uint mNarrowFromPass = 2;
    uint mNarrowEachNthPass = 1;
    uint mMaxPassCount = 5;
    float mDecay = 0.5f;
    // TODO: make it either global for other passes, or with separate ui setting here
    float mGuidedRayProb = 0.5f;
    bool mUseAnalyticLights = true;
    bool mIntegrateLastHits = true;
    float3 mIntensityFactor = float3(0.333, 0.333, 0.333);
    //float3 mIntensityFactor = float3(0.299, 0.587, 0.114);

    std::vector<DensityNode> mTempLocalNodes;
    uint mPassCount = 0;
    bool mOptionsChanged = false;

    // Ray tracing program.
    struct
    {
        ref<Program> pProgram;
        ref<RtBindingTable> pBindingTable;
        ref<RtProgramVars> pVars;
    } mTracer;
};
