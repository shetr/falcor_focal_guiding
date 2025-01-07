# Falcor Focal Guiding

Reimplementation of [Focal Path Guiding for Light Transport Simulation](https://github.com/iRath96/focal-guiding) in [Falcor](https://github.com/NVIDIAGameWorks/Falcor) framework. Most changes to the forked Falcor repository are located in Source/RenderPasses/FocalGuiding. Build according to the original [Falcor README](FALCOR_README.md).

To build follow the instructions from [Falcor README](FALCOR_README.md).

To run the Focal Path Guiding implementation run the Mogwai application, then:
 - in the File menu chose Load Script, then select some Python script from my_scripts folder, for example my_scripts\run_FocalGuidingViz.py
 - chose scene in the File menu with Load Scene, then select some .pyscene file from my_scenes folder, for example my_scenes\cornell_box_lens.pyscene
 - the render should start
 - you can switch to visualization in the output combo-box
 - parameters of each render pass can be tweaked in their respecive sections
