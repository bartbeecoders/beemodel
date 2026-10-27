I want you to create a shell for a application that will host a 3d modeling tool.
Fully written in assembly, being able to run on this computer.
You cannot use any libraries, everything needs to be build from scratch.
Performance and memory usage is the main priority.

Start building the shell:
- canvas where we will model the 3d objects
- title bar with close button
- menu system
- resizable panes for menu items, buttons etc


Deliver also a script to compile and build the app
Deliver a script to start the app

Now that we implemented most of the basics, can we work out a plan to improve the applications UI.
- Make a list of UI improvements.
- Include UI components for all of the features so the user can use that instead of the command line.
- Make the ui intuative, mouse input, keyboard input, clear text and colors

First make a complete plan (html) then start implmenting the improvements one by one.

Add the possibility to ue PBR materials, together with a full node like editor for material (see unreal engine) 

Add the possibility to import and export blender files

Add realtime raycast render canvas. Use the GPU for this.

Add the following to the outliner


Ok add an 2.0 plan, add masterplans open questions and focus on physics:

- Add a feature that breaks an object into x amount of smaller bricks or balls, all physics enabled
- add objects that can serve as ground or landscape
- add gravity objects that can attract objects
- add a particle system (liquid, smoke, fire)

Create a complete plan for this (html file) so we can work it out step by step.


Next steps:
Before we continue onn th eopen parts in plan 2.0, I want to work on some improvements again on the UI.
- color selectors show be with a color picker 
- more clearer UI on physics, landscapes
- improved, more powerfull file dialog (include other drives, favorites etc)
- I cannot select another theme, seems to be a bug ?
- add more themes
- add the possibility for folders in the outliner
- add the possibility to insert reference images

Add the following to the plan and open list and start implementing:

Text generation
ALlow for the user to add Text as 3d object
Enable animation for text
Make sure we can use AI to add, modify text

Reference image import:
Improve the way we can import reference images.
Usually I have reference images of a building in a folder or in pdf file(s).
I want beemodel to be smart enough to open the folder, extract the files that are useful (even extract images from bitmaps etc). You can use the AI assistent for that if needed.
So: user shows you the folder where the files are, you analyse (with ai?) and import the usefull images, add them to the canvas.
Create a seperate branch for this change.