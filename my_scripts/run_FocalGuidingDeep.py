from falcor import *

import importlib.util
import sys

dir_path = os.path.dirname(os.path.realpath(__file__))
script_path = dir_path + "/render_graphs/FocalGuiding.py"

spec = importlib.util.spec_from_file_location("render_graphs", script_path)
render_graphs = importlib.util.module_from_spec(spec)
sys.modules["render_graphs"] = render_graphs
spec.loader.exec_module(render_graphs)

FocalGuiding = render_graphs.render_graph_FocalGuiding(densityPasses=15, narrowFromPass=5, maxBounces=2, maxNodesSize=2000, maxOctreeDepth=10)
try: m.addGraph(FocalGuiding)
except NameError: None