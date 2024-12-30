from falcor import *

def render_graph_WireframePass():
    g = RenderGraph('MyTestPass')
    MyTestPass = createPass("MyTestPass")
    g.addPass(MyTestPass, "MyTestPass")
    g.markOutput("MyTestPass.output")
    return g

WireframePass = render_graph_WireframePass()
try: m.addGraph(WireframePass)
except NameError: None