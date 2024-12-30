from falcor import *
import os

dir_path = os.path.dirname(os.path.realpath(__file__))
m.script(dir_path + "/render_graphs/FocalGuiding.py")
