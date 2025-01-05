from falcor import *

import importlib.util
import sys

dir_path = os.path.dirname(os.path.realpath(__file__))
script_path = dir_path + "/render_graphs/FocalGuidingViz.py"

spec = importlib.util.spec_from_file_location("render_graphs", script_path)
render_graphs = importlib.util.module_from_spec(spec)
sys.modules["render_graphs"] = render_graphs
spec.loader.exec_module(render_graphs)

FocalGuidingViz = render_graphs.render_graph_FocalGuidingViz(densityPasses=3, narrowFromPass=2, maxBounces=3, maxNodesSize=200, maxOctreeDepth=3)
try: m.addGraph(FocalGuidingViz)
except NameError: None
