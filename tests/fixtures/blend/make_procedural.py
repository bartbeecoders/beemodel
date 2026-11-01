"""Makes the procedural-material fixture of tests/blend.py with Blender
itself: a plane per material whose Base Color comes through shader nodes
(gradients, ramps, mixes, mapping, math, hue/saturation, Voronoi, an image
through a mapping, a node group), and what Blender bakes of each (its
diffuse colour, linear, through the plane's UVs) next to it
(<name>.json).

    blender -b --factory-startup --python tests/fixtures/blend/make_procedural.py -- <out.blend>

Blender 5.2 made the committed one.
"""
import bpy, json, math, os, sys

out = sys.argv[sys.argv.index('--') + 1]
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
SIZE = 16


def material(name):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes['Principled BSDF']
    bsdf.inputs['Specular IOR Level'].default_value = 0     # (the bake: base colour)
    return m, nt, bsdf


def link(nt, a, b):
    nt.links.new(a, b)


def ramp(nt, stops, interp='LINEAR'):
    r = nt.nodes.new('ShaderNodeValToRGB')
    r.color_ramp.interpolation = interp
    els = r.color_ramp.elements
    while len(els) < len(stops):
        els.new(0.5)
    for e, (pos, col) in zip(els, stops):
        e.position = pos
        e.color = (*col, 1)
    return r


def mapping(nt, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1), kind='POINT'):
    m = nt.nodes.new('ShaderNodeMapping')
    m.vector_type = kind
    m.inputs['Location'].default_value = loc
    m.inputs['Rotation'].default_value = rot
    m.inputs['Scale'].default_value = scale
    return m


def gradient(nt, kind):
    g = nt.nodes.new('ShaderNodeTexGradient')
    g.gradient_type = kind
    return g


def mix(nt, blend='MIX', fac=0.5, a=None, b=None, kind='RGBA'):
    m = nt.nodes.new('ShaderNodeMix')
    m.data_type = kind
    if kind == 'RGBA':
        m.blend_type = blend
    m.inputs['Factor'].default_value = fac
    sock = {'RGBA': 6, 'FLOAT': 2}[kind]
    if a is not None:
        m.inputs[sock].default_value = a
    if b is not None:
        m.inputs[sock + 1].default_value = b
    out = m.outputs[{'RGBA': 2, 'FLOAT': 0}[kind]]
    return m, m.inputs[sock], m.inputs[sock + 1], out


mats = {}

# the plants' pattern: UV -> Mapping (turned) -> Gradient -> Mix of two ramps
m, nt, bsdf = material('Weeds')
tc = nt.nodes.new('ShaderNodeTexCoord')
mp = mapping(nt, loc=(-0.23, 0, 0), rot=(0, 0, -math.pi / 2), scale=(1, 1.03, 1))
g = gradient(nt, 'LINEAR')
r1 = ramp(nt, [(0.0, (0, 0, 0)), (1.0, (0.156, 0.177, 0.069))])
r2 = ramp(nt, [(0.486, (0, 0, 0)), (1.0, (0.446, 0.432, 0.299))])
mx, a, b, o = mix(nt)
link(nt, tc.outputs['UV'], mp.inputs['Vector'])
link(nt, mp.outputs['Vector'], g.inputs['Vector'])
link(nt, g.outputs['Color'], mx.inputs['Factor'])
link(nt, g.outputs['Fac'], r1.inputs['Fac'])
link(nt, g.outputs['Fac'], r2.inputs['Fac'])
link(nt, r2.outputs['Color'], a)
link(nt, r1.outputs['Color'], b)
link(nt, o, bsdf.inputs['Base Color'])
mats['Weeds'] = m

# easing on Generated, a three-stop ramp
m, nt, bsdf = material('Ease')
tc = nt.nodes.new('ShaderNodeTexCoord')
g = gradient(nt, 'EASING')
r = ramp(nt, [(0.1, (0.9, 0.1, 0.1)), (0.5, (0.1, 0.8, 0.2)), (0.9, (0.1, 0.2, 0.9))])
link(nt, tc.outputs['Generated'], g.inputs['Vector'])
link(nt, g.outputs['Fac'], r.inputs['Fac'])
link(nt, r.outputs['Color'], bsdf.inputs['Base Color'])
mats['Ease'] = m

# radial and quadratic sphere, centred; constant and B-spline ramps
m, nt, bsdf = material('Radial')
tc = nt.nodes.new('ShaderNodeTexCoord')
mp = mapping(nt, loc=(-0.5, -0.5, 0))
g = gradient(nt, 'RADIAL')
r = ramp(nt, [(0.0, (1, 1, 0)), (0.5, (0, 0.3, 1)), (0.75, (1, 0, 0.5))], 'CONSTANT')
link(nt, tc.outputs['UV'], mp.inputs['Vector'])
link(nt, mp.outputs['Vector'], g.inputs['Vector'])
link(nt, g.outputs['Fac'], r.inputs['Fac'])
link(nt, r.outputs['Color'], bsdf.inputs['Base Color'])
mats['Radial'] = m

m, nt, bsdf = material('Sphere')
tc = nt.nodes.new('ShaderNodeTexCoord')
mp = mapping(nt, loc=(-0.5, -0.5, 0), scale=(1.6, 1.6, 1))
g = gradient(nt, 'QUADRATIC_SPHERE')
r = ramp(nt, [(0.0, (0.05, 0.05, 0.3)), (1.0, (1, 0.9, 0.2))])
link(nt, tc.outputs['UV'], mp.inputs['Vector'])
link(nt, mp.outputs['Vector'], g.inputs['Vector'])
link(nt, g.outputs['Fac'], r.inputs['Fac'])
link(nt, r.outputs['Color'], bsdf.inputs['Base Color'])
mats['Sphere'] = m

# a texture-type mapping (turned, scaled) into a diagonal gradient, math
#   (multiply, clamped), a float mix, a ramp
m, nt, bsdf = material('Diagonal')
tc = nt.nodes.new('ShaderNodeTexCoord')
mp = mapping(nt, loc=(0.1, 0.2, 0), rot=(0, 0, math.radians(30)), scale=(0.8, 1.2, 1), kind='TEXTURE')
g = gradient(nt, 'DIAGONAL')
mt = nt.nodes.new('ShaderNodeMath')
mt.operation = 'MULTIPLY'
mt.use_clamp = True
mt.inputs[1].default_value = 1.4
mf, fa, fb, fo = mix(nt, kind='FLOAT', fac=0.3, b=0.9)
r = ramp(nt, [(0.0, (0.2, 0.05, 0.4)), (1.0, (0.95, 0.85, 0.6))])
link(nt, tc.outputs['UV'], mp.inputs['Vector'])
link(nt, mp.outputs['Vector'], g.inputs['Vector'])
link(nt, g.outputs['Fac'], mt.inputs[0])
link(nt, mt.outputs[0], fa)
link(nt, fo, r.inputs['Fac'])
link(nt, r.outputs['Color'], bsdf.inputs['Base Color'])
mats['Diagonal'] = m

# hue / saturation / value and a multiply mix over a quadratic gradient on
#   Object coordinates; an RGB node; an Invert; a node group passing its
#   input through
m, nt, bsdf = material('Tinted')
tc = nt.nodes.new('ShaderNodeTexCoord')
g = gradient(nt, 'QUADRATIC')
mp = mapping(nt, loc=(0.5, 0, 0))
rgb = nt.nodes.new('ShaderNodeRGB')
rgb.outputs[0].default_value = (0.2, 0.6, 0.3, 1)
hsv = nt.nodes.new('ShaderNodeHueSaturation')
hsv.inputs['Hue'].default_value = 0.6
hsv.inputs['Saturation'].default_value = 1.3
hsv.inputs['Value'].default_value = 0.8
mx, a, b, o = mix(nt, 'MULTIPLY', 0.8)
grp = bpy.data.node_groups.new('Pass', 'ShaderNodeTree')
grp.interface.new_socket('In', in_out='INPUT', socket_type='NodeSocketColor')
grp.interface.new_socket('Out', in_out='OUTPUT', socket_type='NodeSocketColor')
gi = grp.nodes.new('NodeGroupInput')
go = grp.nodes.new('NodeGroupOutput')
grp.links.new(gi.outputs[0], go.inputs[0])
inv = nt.nodes.new('ShaderNodeInvert')
inv.inputs['Fac'].default_value = 0.7
gn = nt.nodes.new('ShaderNodeGroup')
gn.node_tree = grp
link(nt, tc.outputs['Object'], mp.inputs['Vector'])
link(nt, mp.outputs['Vector'], g.inputs['Vector'])
link(nt, rgb.outputs[0], hsv.inputs['Color'])
link(nt, g.outputs['Color'], a)
link(nt, hsv.outputs[0], b)
link(nt, o, gn.inputs[0])
link(nt, gn.outputs[0], inv.inputs['Color'])
link(nt, inv.outputs[0], bsdf.inputs['Base Color'])
mats['Tinted'] = m

# the MixRGB node of files before Blender 3.4 (difference), fed by a power
m, nt, bsdf = material('Legacy')
tc = nt.nodes.new('ShaderNodeTexCoord')
g = gradient(nt, 'LINEAR')
mt = nt.nodes.new('ShaderNodeMath')
mt.operation = 'POWER'
mt.inputs[1].default_value = 2.0
mr = nt.nodes.new('ShaderNodeMixRGB')
mr.blend_type = 'DIFFERENCE'
mr.inputs['Color1'].default_value = (0.8, 0.3, 0.1, 1)
mr.inputs['Color2'].default_value = (0.2, 0.6, 0.9, 1)
link(nt, tc.outputs['UV'], g.inputs['Vector'])
link(nt, g.outputs['Fac'], mt.inputs[0])
link(nt, mt.outputs[0], mr.inputs['Fac'])
link(nt, mr.outputs[0], bsdf.inputs['Base Color'])
mats['Legacy'] = m

# Voronoi cells (their colour), darkened by the distance: a pattern of our
#   own hash, so only its spread is compared
m, nt, bsdf = material('Cells')
tc = nt.nodes.new('ShaderNodeTexCoord')
v = nt.nodes.new('ShaderNodeTexVoronoi')
v.inputs['Scale'].default_value = 6
mx, a, b, o = mix(nt, 'MULTIPLY', 1.0)
link(nt, tc.outputs['UV'], v.inputs['Vector'])
link(nt, v.outputs['Color'], a)
link(nt, v.outputs['Distance'], b)
link(nt, o, bsdf.inputs['Base Color'])
mats['Cells'] = m

# an image (packed) through a mapping that tiles it twice, tinted by a mix
#   (material.bake does not sample images: checked by its graph)
m, nt, bsdf = material('Tiled')
img = bpy.data.images.new('stripes', 8, 8)
px = []
for y in range(8):
    for x in range(8):
        on = (x // 2) % 2
        px += [0.9 * on + 0.05, 0.3, 0.9 - 0.8 * on, 1.0]
img.pixels = px
img.pack()
tc = nt.nodes.new('ShaderNodeTexCoord')
mp = mapping(nt, scale=(2, 2, 1))
t = nt.nodes.new('ShaderNodeTexImage')
t.image = img
t.interpolation = 'Closest'
mx, a, b, o = mix(nt, 'MIX', 0.25, b=(1, 1, 0, 1))
link(nt, tc.outputs['UV'], mp.inputs['Vector'])
link(nt, mp.outputs['Vector'], t.inputs['Vector'])
link(nt, t.outputs['Color'], a)
link(nt, o, bsdf.inputs['Base Color'])
mats['Tiled'] = m

for i, (name, m) in enumerate(mats.items()):
    bpy.ops.mesh.primitive_plane_add(size=2, location=(3 * i, 0, 0))
    ob = bpy.context.object
    ob.name = name
    ob.data.materials.append(m)

bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(out), compress=True)

# what Blender makes of them: the diffuse colour baked through the UVs
scene.render.engine = 'CYCLES'
scene.cycles.samples = 1
scene.cycles.device = 'CPU'
info = {'version': bpy.app.version_string, 'size': SIZE, 'bakes': {}}
for name in mats:
    ob = bpy.data.objects[name]
    im = bpy.data.images.new(name + '_bake', SIZE, SIZE, float_buffer=True)
    t = ob.active_material.node_tree.nodes.new('ShaderNodeTexImage')
    t.image = im
    ob.active_material.node_tree.nodes.active = t
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.bake(type='DIFFUSE', pass_filter={'COLOR'}, margin=0)
    p = list(im.pixels)
    info['bakes'][name] = [[round(p[(y * SIZE + x) * 4 + c], 5) for c in range(3)]
                           for y in range(SIZE) for x in range(SIZE)]
json.dump(info, open(os.path.splitext(out)[0] + '.json', 'w'))
