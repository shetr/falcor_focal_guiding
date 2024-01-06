add_plugin(MyTestPass)

target_sources(MyTestPass PRIVATE
    MyTestPass.cpp
    MyTestPass.h
    MyTestShader.slang
)

target_copy_shaders(MyTestPass RenderPasses/MyTestPass)

target_source_group(MyTestPass "RenderPasses")
