from falcor import *

import importlib.util
import sys

dir_path = os.path.dirname(os.path.realpath(__file__))
script_path = dir_path + "/render_graphs/MinimalPathTracer.py"

spec = importlib.util.spec_from_file_location("render_graphs", script_path)
render_graphs = importlib.util.module_from_spec(spec)
sys.modules["render_graphs"] = render_graphs
spec.loader.exec_module(render_graphs)

MinimalPathTracer = render_graphs.render_graph_MinimalPathTracer()
try: m.addGraph(MinimalPathTracer)
except NameError: None
