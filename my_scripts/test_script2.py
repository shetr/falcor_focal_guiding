from falcor import *

import importlib.util
import sys
import os

m = Testbed(create_window=True, width=1024, height=1024)

print(dir(m))

m.clock.pause()

dir_path = os.path.dirname(os.path.realpath(__file__))
script_path = dir_path + "/render_graphs/FocalGuiding.py"

m.load_render_graph(script_path)

#spec = importlib.util.spec_from_file_location("render_graphs", script_path)
#render_graphs = importlib.util.module_from_spec(spec)
#sys.modules["render_graphs"] = render_graphs
#spec.loader.exec_module(render_graphs)
#
#FocalGuiding = render_graphs.render_graph_FocalGuiding()
#try: m.addGraph(FocalGuiding)
#except NameError: None

scene_path = dir_path + "/../my_scenes/focal_points/lens2.pyscene"
m.load_scene(scene_path)

print(str(m.clock.exitFrame))
print(str(m.clock.exitTime))

frames = {20, 50, 100}
for i in range(201):
    m.frame()
    print(str(i))
    print(str(m.clock.frame))
    print(str(m.clock.time))
    if i in frames:
        #print(str(i))
        m.capture_output("out")

exit()
