"""Makes the .blend fixtures of tests/blend.py with Blender itself, and
writes what Blender says about each scene next to it (<name>.json): the
objects BeeModel should import (their world matrices, mesh counts, first
UVs, materials), the cameras and lights.

    blender -b --factory-startup --python tests/fixtures/blend/make.py -- <out.blend>

Blender 5.2 and 4.2 made the committed fixtures (saved compressed: zstd).
"""
import bpy, json, math, os, sys

out = sys.argv[sys.argv.index('--') + 1]
here = os.path.dirname(os.path.abspath(out))
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def principled(name, base, metallic=0.0, roughness=0.5, emission=None, alpha=1.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes.get('Principled BSDF')
    b.inputs['Base Color'].default_value = (*base, 1)
    b.inputs['Metallic'].default_value = metallic
    b.inputs['Roughness'].default_value = roughness
    b.inputs['Alpha'].default_value = alpha
    if emission:
        b.inputs['Emission Color'].default_value = (*emission, 1)
        b.inputs['Emission Strength'].default_value = 2.0
    return m, b


def textured(name, image):
    m, b = principled(name, (1, 1, 1), roughness=0.7)
    t = m.node_tree.nodes.new('ShaderNodeTexImage')
    t.image = image
    m.node_tree.links.new(t.outputs['Color'], b.inputs['Base Color'])
    return m


def checker(name, w, h, path=None):
    img = bpy.data.images.new(name, w, h)
    px = []
    for y in range(h):
        for x in range(w):
            on = (x + y) % 2
            px += [0.9 * on + 0.05, 0.2 + 0.5 * on, 0.1, 1.0]
    img.pixels = px
    if path:
        img.filepath_raw = path
        img.file_format = 'PNG'
        img.save()
        img.filepath = '//' + os.path.basename(path)
    else:
        img.pack()
    return img


red, _ = principled('Red', (0.8, 0.1, 0.1), roughness=0.3)
gold, _ = principled('Gold', (1.0, 0.77, 0.34), metallic=1.0, roughness=0.2)
glow, _ = principled('Glow', (0.1, 0.1, 0.1), emission=(0.2, 0.9, 0.3))
packed = textured('Packed', checker('checker', 8, 8))
external = textured('External', checker('tiles', 4, 4, os.path.join(here, 'tiles.png')))

bpy.ops.mesh.primitive_cube_add(location=(1, 2, 3), rotation=(math.radians(10), math.radians(20), math.radians(30)))
box = bpy.context.object
box.name = 'Box'
box.scale = (1, 2, 0.5)
box.data.materials.append(red)
box.modifiers.new('Subdiv', 'SUBSURF')

bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=8, location=(-2, 0, 1))
ball = bpy.context.object
ball.name = 'Ball'
bpy.ops.object.shade_smooth()
ball.data.materials.append(gold)

bpy.ops.mesh.primitive_plane_add(size=2, location=(0, 0, -1))
plate = bpy.context.object
plate.name = 'Plate'
plate.data.materials.append(packed)

bpy.ops.mesh.primitive_plane_add(size=1, location=(3, 0, -1))
tile = bpy.context.object
tile.name = 'Tile'
tile.data.materials.append(external)

# an n-gon: a pentagon, plus a quad, two materials
import bmesh
me = bpy.data.meshes.new('PentaMesh')
bm = bmesh.new()
vs = [bm.verts.new((math.cos(a * 2 * math.pi / 5), math.sin(a * 2 * math.pi / 5), 0)) for a in range(5)]
bm.faces.new(vs)
q = [bm.verts.new(p) for p in ((2, 0, 0), (3, 0, 0), (3, 1, 0), (2, 1, 0))]
f = bm.faces.new(q)
f.material_index = 1
bm.to_mesh(me)
penta = bpy.data.objects.new('Penta', me)
scene.collection.objects.link(penta)
penta.location = (0, 4, 0)
me.materials.append(red)
me.materials.append(glow)

# a child of Box (its world matrix: Box's times its own)
bpy.ops.mesh.primitive_cone_add(location=(0, 0, 0))
child = bpy.context.object
child.name = 'Child'
child.parent = box
child.location = (0, 0, 2)

# two objects sharing one mesh
bpy.ops.mesh.primitive_cylinder_add(vertices=12, location=(-4, 2, 0))
a = bpy.context.object
a.name = 'PairA'
b = a.copy()
b.name = 'PairB'
b.location = (-4, -2, 0)
scene.collection.objects.link(b)

# nested collections; one excluded from the view layer
props = bpy.data.collections.new('Props')
scene.collection.children.link(props)
inner = bpy.data.collections.new('Inner')
props.children.link(inner)
bpy.ops.mesh.primitive_torus_add(major_segments=12, minor_segments=6, location=(0, -4, 0))
tor = bpy.context.object
tor.name = 'Ring'
for c in tor.users_collection:
    c.objects.unlink(tor)
inner.objects.link(tor)
hidden = bpy.data.collections.new('Hidden')
scene.collection.children.link(hidden)
bpy.ops.mesh.primitive_ico_sphere_add(location=(5, 5, 5))
hid = bpy.context.object
hid.name = 'Excluded'
for c in hid.users_collection:
    c.objects.unlink(hid)
hidden.objects.link(hid)
bpy.context.view_layer.layer_collection.children['Hidden'].exclude = True

bpy.ops.object.camera_add(location=(0, -10, 4), rotation=(math.radians(75), 0, 0))
cam = bpy.context.object
cam.name = 'Cam'
cam.data.lens = 35
scene.camera = cam
bpy.ops.object.light_add(type='POINT', location=(2, -3, 5))
lamp = bpy.context.object
lamp.name = 'Lamp'
lamp.data.energy = 500
lamp.data.color = (1.0, 0.9, 0.8)
bpy.ops.object.light_add(type='SUN', location=(0, 0, 10), rotation=(math.radians(30), 0, math.radians(45)))
sun = bpy.context.object
sun.name = 'Sun'
sun.data.energy = 3

bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(out), compress=True)

# what Blender says
info = {'version': bpy.app.version_string, 'objects': {}, 'materials': {}}
vl = bpy.context.view_layer
for o in scene.objects:
    e = {'type': o.type, 'visible': o.visible_get(view_layer=vl) or not o.hide_get() and o.name in vl.objects,
         'in_view_layer': o.name in vl.objects,
         'matrix': [list(r) for r in o.matrix_world]}
    if o.type == 'MESH':
        m = o.data
        e['mesh'] = m.name
        e['verts'], e['faces'], e['loops'] = len(m.vertices), len(m.polygons), len(m.loops)
        e['ngon_sides'] = sorted({p.loop_total for p in m.polygons})
        e['smooth'] = [p.use_smooth for p in m.polygons][:4]
        e['first_verts'] = [list(v.co) for v in m.vertices][:3]
        e['first_face'] = list(m.polygons[0].vertices)
        uv = m.uv_layers.active
        e['first_uvs'] = [list(uv.data[i].uv) for i in range(min(4, len(m.loops)))] if uv else []
        e['materials'] = [s.material.name if s.material else None for s in o.material_slots]
        e['material_index'] = [p.material_index for p in m.polygons][:4]
        e['modifiers'] = [md.type for md in o.modifiers]
    if o.type == 'CAMERA':
        e['lens'] = o.data.lens
    if o.type == 'LIGHT':
        e['light'] = o.data.type
        e['energy'] = o.data.energy
        e['color'] = list(o.data.color)
    info['objects'][o.name] = e
for m in bpy.data.materials:
    b = m.node_tree.nodes.get('Principled BSDF') if m.node_tree else None
    if not b:
        continue
    g = lambda k: b.inputs[k].default_value
    tex = [n.image.name for n in m.node_tree.nodes if n.type == 'TEX_IMAGE' and n.image]
    info['materials'][m.name] = {'base': list(g('Base Color'))[:3], 'metallic': g('Metallic'),
                                 'roughness': g('Roughness'), 'alpha': g('Alpha'),
                                 'emission': list(g('Emission Color'))[:3], 'emission_strength': g('Emission Strength'),
                                 'images': tex}
json.dump(info, open(os.path.splitext(out)[0] + '.json', 'w'), indent=1)
