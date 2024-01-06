add_plugin(DirectRayTracer)

target_sources(DirectRayTracer PRIVATE
    DirectRayTracer.cpp
    DirectRayTracer.h
    DirectRayTracer.rt.slang
    SimplePathTracer.h
    SimplePathTracer.cpp
    SimplePathTracer.rt.slang
)

target_copy_shaders(DirectRayTracer RenderPasses/DirectRayTracer)

target_source_group(DirectRayTracer "RenderPasses")
