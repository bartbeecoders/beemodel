"""Makes the collection-instance fixture of tests/blend.py with Blender
itself, and writes what Blender says about it next to it (<name>.json):
every mesh Blender draws (instanced or not) with its world matrix.

    blender -b --factory-startup --python tests/fixtures/blend/make_instances.py -- <out.blend>

The scene: the sources of the instances sit in an excluded collection (as
asset packs keep them); two empties instance it, one rotated and scaled,
with the collection's instance offset; a third instances a collection that
holds an instancer itself (an instance in an instance); a visible collection
is instanced too (its object comes in twice); a fog cube (a volume-only
material) and a plain empty are skipped. Blender 5.2 made the committed one.
"""
import bpy, json, math, os, sys

out = sys.argv[sys.argv.index('--') + 1]
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
vl = bpy.context.view_layer


def move(ob, coll):
    for c in ob.users_collection:
        c.objects.unlink(ob)
    coll.objects.link(ob)


def collection(name, parent=None):
    c = bpy.data.collections.new(name)
    (parent or scene.collection).children.link(c)
    return c


def instancer(name, coll, loc, rot=(0, 0, 0), scale=1.0, into=None):
    e = bpy.data.objects.new(name, None)
    e.instance_type = 'COLLECTION'
    e.instance_collection = coll
    e.location = loc
    e.rotation_euler = rot
    e.scale = (scale, scale, scale)
    (into or scene.collection).objects.link(e)
    return e


# the sources: a tree (trunk with a crown parented to it) and, in a child
# collection, a rock; offset so the trunk's foot is the instance's origin
src = collection('Sources')
bpy.ops.mesh.primitive_cylinder_add(vertices=8, radius=0.2, depth=2, location=(1, 0, 1))
trunk = bpy.context.object
trunk.name = 'Trunk'
move(trunk, src)
bpy.ops.mesh.primitive_cone_add(vertices=8, radius1=1, depth=2, location=(0, 0, 0))
crown = bpy.context.object
crown.name = 'Crown'
crown.parent = trunk
crown.location = (0, 0, 2)
move(crown, src)
sub = collection('Rocks', src)
bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=0.5, location=(2, 1, 0))
rock = bpy.context.object
rock.name = 'Rock'
move(rock, sub)
src.instance_offset = (1, 0, 0)

# an instancer kept with the sources: instanced, it instances them again
pair = collection('Pair')
instancer('PairTree', src, (0, 3, 0), into=pair)

# a visible collection, instanced as well
vis = collection('Visible')
bpy.ops.mesh.primitive_cube_add(size=1, location=(0, -3, 0.5))
crate = bpy.context.object
crate.name = 'Crate'
move(crate, vis)

instancer('TreeA', src, (5, 0, 0), rot=(0, 0, math.radians(90)), scale=2.0)
instancer('TreeB', src, (-5, 3, 0), rot=(0, 0, math.radians(-30)))
instancer('Twice', pair, (0, -8, 0), rot=(0, 0, math.radians(45)), scale=0.5)
instancer('Crates', vis, (4, -4, 0))
plain = bpy.data.objects.new('Plain', None)
scene.collection.objects.link(plain)

# fog: a cube whose material is a Principled Volume only
bpy.ops.mesh.primitive_cube_add(size=4, location=(0, 0, 2))
fog = bpy.context.object
fog.name = 'Fog'
m = bpy.data.materials.new('Fog')
m.use_nodes = True
nt = m.node_tree
nt.nodes.remove(nt.nodes['Principled BSDF'])
vol = nt.nodes.new('ShaderNodeVolumePrincipled')
nt.links.new(vol.outputs['Volume'], nt.nodes['Material Output'].inputs['Volume'])
fog.data.materials.append(m)

for name in ('Sources', 'Pair'):
    vl.layer_collection.children[name].exclude = True

bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(out), compress=True)

# what Blender draws: each mesh (instanced or not) with its world matrix
dg = bpy.context.evaluated_depsgraph_get()
meshes = []
for inst in dg.object_instances:
    o = inst.object.original
    if o.type != 'MESH' or o.name == 'Fog':
        continue
    meshes.append({'name': o.name, 'instanced': inst.is_instance, 'verts': len(o.data.vertices),
                   'matrix': [list(r) for r in inst.matrix_world]})
info = {'version': bpy.app.version_string, 'meshes': meshes}
json.dump(info, open(os.path.splitext(out)[0] + '.json', 'w'), indent=1)
