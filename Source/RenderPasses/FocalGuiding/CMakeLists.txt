add_plugin(FocalGuiding)

target_sources(FocalGuiding PRIVATE
    FocalGuiding.cpp
    FocalGuiding.h
    FocalGuiding.rt.slang
    FocalDensities.cpp
    FocalDensities.h
    FocalDensities.rt.slang
    FocalViz.cpp
    FocalViz.h
    FocalViz.rt.slang
    DensityNode.h
    DensityNode.slang
)

target_copy_shaders(FocalGuiding RenderPasses/FocalGuiding)

target_source_group(FocalGuiding "RenderPasses")
