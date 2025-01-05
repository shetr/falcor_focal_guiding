import numpy as np
import matplotlib.pyplot as plt   # for drawing and image I/O

import sys

if len(sys.argv) != 3:
    print("need 2 input files")
    exit()

file_name1 = sys.argv[1]
file_name2 = sys.argv[2]

image1 = plt.imread(file_name1)
image2 = plt.imread(file_name2)

mse = np.average((image1 - image2) ** 2)

print(mse)
