#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"

#include "DensityNode.h"

using namespace Falcor;

class FocalGuiding : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(FocalGuiding, "FocalGuiding", "Insert pass description here.");

    static ref<FocalGuiding> create(ref<Device> pDevice, const Properties& props) { return make_ref<FocalGuiding>(pDevice, props); }

    FocalGuiding(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    void parseProperties(const Properties& props);
    void prepareVars();

    // Internal state
    ref<Scene> mpScene; ///< Current scene.
    ref<SampleGenerator> mpSampleGenerator; ///< GPU sample generator.
    ref<Buffer> mNodes;
    ref<ParameterBlock> mpNodesBlock;

    uint mNodesSize = 1;
    uint mMaxOctreeDepth = 3;

    // Configuration
    uint mMaxBounces = 3;               ///< Max number of indirect bounces (0 = none).
    bool mComputeDirect = true;         ///< Compute direct illumination (otherwise indirect only).
    bool mUseImportanceSampling = true; ///< Use importance sampling for materials.

    // Runtime data
    uint mFrameCount = 0; ///< Frame count since scene was loaded.
    float mGuidedRayProb = 1.0f;
    bool mOptionsChanged = false;

    // Ray tracing program.
    struct
    {
        ref<Program> pProgram;
        ref<RtBindingTable> pBindingTable;
        ref<RtProgramVars> pVars;
    } mTracer;
};
