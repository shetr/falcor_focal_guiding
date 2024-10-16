#include "GuidedRayViz.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

#include "Scene/Material/StandardMaterial.h"

namespace
{
const char kShaderFile[] = "RenderPasses/FocalGuiding/GuidedRayViz.slang";

} // namespace

GuidedRayViz::GuidedRayViz(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    mpProgram = Program::createGraphics(mpDevice, kShaderFile, "vsMain", "psMain");
    RasterizerState::Desc wireframeDesc;
    wireframeDesc.setFillMode(RasterizerState::FillMode::Solid);
    wireframeDesc.setCullMode(RasterizerState::CullMode::Back);
    mpRasterState = RasterizerState::create(wireframeDesc);

    mpGraphicsState = GraphicsState::create(mpDevice);
    mpGraphicsState->setProgram(mpProgram);
    mpGraphicsState->setRasterizerState(mpRasterState);
}

Properties GuidedRayViz::getProperties() const
{
    return {};
}

RenderPassReflection GuidedRayViz::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    //reflector.addInput("input", "lines color");
    reflector.addOutput("output", "linesColor");
    return reflector;
}

void GuidedRayViz::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpScene)
    {
        return;
    }

    Dictionary& dict = renderData.getDictionary();
    mGuidedRaysSize = dict["gGuidedRaysSize"];
    mGuidedRays = dict["gGuidedRays"];
    dict["gComputeRays"] = mComputeRays;
    
    //if ((mComputeRays || !mpRayScene) && mGuidedRays)
    //{
    //}

    auto pTargetFbo = Fbo::create(mpDevice, {renderData.getTexture("output")});
    const float4 clearColor(0, 0, 0, 1);
    pRenderContext->clearFbo(pTargetFbo.get(), clearColor, 1.0f, 0, FboAttachmentType::All);
    mpGraphicsState->setFbo(pTargetFbo);

    if (mpScene)
    {
        //auto var = mpVars->getRootVar();
        //var["PerFrameCB"]["gColor"] = float4(0, 1, 0, 1);
        //
        //mpScene->rasterize(pRenderContext, mpGraphicsState.get(), mpVars.get(), mpRasterState, mpRasterState);
    }

    if (mpRayScene)
    {
        //*mpRayScene->getCamera().get() = *mpScene->getCamera().get();
        //mpRayScene->getCamera()->setName("test");

        //mpRayScene->update(pRenderContext, renderData. ->getGlobalClock().now());
        mpRayScene->update(pRenderContext, 0.0);
        
        // render rays
        auto var = mpVars->getRootVar();
        var["PerFrameCB"]["gColor"] = float4(1, 1, 0, 1);
        var["PerFrameCB"]["gShadedLines"] = mShadedLines;

        mpRayScene->rasterize(pRenderContext, mpGraphicsState.get(), mpVars.get(), mpRasterState, mpRasterState);
    }
}

void GuidedRayViz::renderUI(Gui::Widgets& widget)
{
    widget.slider("Line length scale", mLineLengthScale, 0.0f, 1.0f);
    widget.slider("Line width scale", mLineWidthScale, 0.0f, 1.0f);
    bool shouldRecomputeRays = widget.button("Recompute rays");
    if (shouldRecomputeRays)
    {
        mComputeRays = true;
        if (mGuidedRays)
        {
            generateRaysGeometry();
        }
    }
    widget.checkbox("Shaded lines", mShadedLines);
}

void GuidedRayViz::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mpScene = pScene;

    if (mpScene)
        mpProgram->addDefines(mpScene->getSceneDefines());
    mpVars = ProgramVars::create(mpDevice, mpProgram->getReflector());
}

bool GuidedRayViz::onMouseEvent(const MouseEvent& mouseEvent)
{
    if (mouseEvent.type == MouseEvent::Type::ButtonDown && mouseEvent.button == Input::MouseButton::Right)
    {
        if (mShiftPressed)
        {
            mComputeRays = true;
            if (mGuidedRays)
            {
                generateRaysGeometry();
            }
        }
    }
    return mpRayScene ? mpRayScene->onMouseEvent(mouseEvent) : false;
}

bool GuidedRayViz::onKeyEvent(const KeyboardEvent& keyEvent)
{
    if (keyEvent.key == Input::Key::LeftShift)
    {
        if (keyEvent.type == KeyboardEvent::Type::KeyPressed)
        {
            mShiftPressed = true;
        }
        if (keyEvent.type == KeyboardEvent::Type::KeyReleased)
        {
            mShiftPressed = false;
        }
    }
    return mpRayScene ? mpRayScene->onKeyEvent(keyEvent) : false;
}

void GuidedRayViz::prepareVars()
{
}

void GuidedRayViz::generateRaysGeometry()
{
    std::vector<GuidedRayLine> rayNodes = mGuidedRays->getElements<GuidedRayLine>(0, mGuidedRaysSize);

    SceneBuilder sceneBuilder = SceneBuilder(mpDevice, {});
    SceneBuilder::ProcessedMesh mesh;
    //mesh.topology = Vao::Topology::LineList;
    mesh.topology = Vao::Topology::TriangleList;
    MaterialSystem matSystem = MaterialSystem(mpDevice);
    mesh.pMaterial = StandardMaterial::create(mpDevice, "lines");

    int index = 0;
    for (uint i = 0; i < mGuidedRaysSize; ++i)
    {
        GuidedRayLine rayLine = rayNodes[i];
        //createLine(mesh, rayLine, index);
        createTube(mesh, rayLine, index);
    }

    auto meshId = sceneBuilder.addProcessedMesh(mesh);
    auto nodeId = sceneBuilder.addNode(SceneBuilder::Node());
    sceneBuilder.addMeshInstance(nodeId, meshId);
    //ref<Camera> camera = Camera::create("lineSceneCam");
    //sceneBuilder.addCamera(camera);
    //sceneBuilder.addCamera(mpScene->getCamera());
    ref<Camera> camera = Camera::create("test");
    *camera.get() = *mpScene->getCamera().get();
    camera->setName("test");
    sceneBuilder.addCamera(camera);

    ref<Scene> newScene = sceneBuilder.getScene();
    mpRayScene.swap(newScene);
    mpRayScene->setCameraController(Scene::CameraControllerType::FirstPerson);
    mpRayScene->setCameraControlsEnabled(true);
}

void GuidedRayViz::createLine(SceneBuilder::ProcessedMesh& mesh, GuidedRayLine rayLine, int& index)
{
    mesh.staticData.push_back({rayLine.pos1, float3(0.0f), float4(0.0f), float2(0.0f), 0.0f});
    mesh.staticData.push_back({rayLine.pos2, float3(0.0f), float4(0.0f), float2(0.0f), 0.0f});
    mesh.indexData.push_back(index + 0);
    mesh.indexData.push_back(index + 1);

    index += 2;
    mesh.indexCount += 2;
}

void GuidedRayViz::createTube(SceneBuilder::ProcessedMesh& mesh, GuidedRayLine rayLine, int& index)
{
    int numSegments = 6;
    float lineWidth = 0.002f * mLineWidthScale;

    float3 s = rayLine.pos1;
    float3 diff = rayLine.pos2 - rayLine.pos1;
    float lineLenght = length(diff) * mLineLengthScale;
    float3 dir = normalize(diff);
    float3 uDir = getPerpendicualrTo(dir);
    float3 vDir = cross(dir, uDir);
    float3 uAxis = uDir * lineWidth;
    float3 vAxis = vDir * lineWidth;
    for (int i = 0; i < numSegments; ++i)
    {
        float phi1 = (float)i * 2.f * M_PI / (float)numSegments;
        float phi2 = ((float)i + 1.f) * 2.f * M_PI / (float)numSegments;
        float u1 = cos(phi1);
        float v1 = sin(phi1);
        float u2 = cos(phi2);
        float v2 = sin(phi2);

        float3 x11 = s + u1 * uAxis + v1 * vAxis;
        float3 x12 = x11 + dir * lineLenght;
        float3 x21 = s + u2 * uAxis + v2 * vAxis;
        float3 x22 = x21 + dir * lineLenght;

        float3 n1 = u1 * uDir + v1 * vDir;
        float3 n2 = u2 * uDir + v2 * vDir;

        createQuad(mesh, index, x11, x12, x21, x22, n1, n1, n2, n2);
    }
}

void GuidedRayViz::createQuad(
    SceneBuilder::ProcessedMesh& mesh,
    int& index,
    float3 x11,
    float3 x12,
    float3 x21,
    float3 x22,
    float3 n11,
    float3 n12,
    float3 n21,
    float3 n22
)
{
    mesh.staticData.push_back({x11, n11, float4(0.0f), float2(0.0f), 0.0f});
    mesh.staticData.push_back({x12, n12, float4(0.0f), float2(0.0f), 0.0f});
    mesh.staticData.push_back({x21, n21, float4(0.0f), float2(0.0f), 0.0f});
    mesh.staticData.push_back({x22, n22, float4(0.0f), float2(0.0f), 0.0f});
    mesh.indexData.push_back(index + 0);
    mesh.indexData.push_back(index + 1);
    mesh.indexData.push_back(index + 2);
    mesh.indexData.push_back(index + 2);
    mesh.indexData.push_back(index + 1);
    mesh.indexData.push_back(index + 3);

    index += 4;
    mesh.indexCount += 4;
}

float3 GuidedRayViz::getPerpendicualrTo(float3 dir)
{
    float epsilon = 0.0001f;
    double length = sqrt(dir.x * dir.x + dir.y * dir.y);
    float3 v;
    if (abs(dir.x) > epsilon && abs(dir.y) > epsilon)
    {
        v = float3(dir.y / length, -dir.x / length, 0);
    }
    else if (abs(dir.y) > epsilon)
    {
        length = sqrt(dir.y * dir.y + dir.z * dir.z);
        v = float3(0, -dir.z / length, dir.y / length);
    }
    else
    {
        length = sqrt(dir.x * dir.x + dir.z * dir.z);
        v = float3(-dir.z / length, 0, dir.x / length);
    }
    return v;
}
