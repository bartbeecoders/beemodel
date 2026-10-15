#!/usr/bin/env python3
"""Generate the data part of src/matnodes.s - the material node catalogue
(names, titles, input / value / output names and kinds, choices, header
colours, categories, defaults) - from the node list below. It rewrites
src/matnodes.s from its "# ---- generated from the node list" line on.

    python3 tools/genmatnodes.py

A new node type: add its row at the end (types are numbered by their place,
from 1; files store the numbers), raise MN_NTYPES at the top of matnodes.s
(the generated part checks it), and add its evaluation to mn_eval's table.
"""
# Generates the data part of src/matnodes.s (node metadata). Kinds:
#  inputs: 1 value 2 vector 3 colour; values: 0 number 1 choice 6 second choice 2 image 3 whole
#  outputs: 1 value 2 vector 3 colour
CAT = ['Input', 'Texture', 'Math', 'Vector', 'Colour', 'Utility', 'Parameters', 'Functions']
COLS = [0x9a4a3c, 0x6b4f96, 0x2f6589, 0x6a3b63, 0x8a6d1f, 0x4a5560, 0x3d6b47, 0x2f6e6e]
MATH_OPS = ['Add','Subtract','Multiply','Divide','Power','Minimum','Maximum','Greater Than','Sine','Absolute',
            'Cosine','Tangent','Square Root','Floor','Ceil','Fraction','Round','Sign','One Minus','Saturate',
            'Clamp','Lerp','Step','Smoothstep','Modulo','Exponent','Logarithm','Arctan2','Less Than','Negate','Multiply Add']
VMATH_OPS = ['Add','Subtract','Multiply','Divide','Minimum','Maximum','Absolute','Floor','Fraction','Scale',
             'Dot Product','Cross Product','Normalize','Length','Distance','Reflect','Lerp','One Minus','Saturate','Power']
MIX = ['Mix','Add','Multiply','Subtract','Screen','Overlay','Darken','Lighten','Difference','Soft Light','Divide']
# name, title, category, inputs [(name,kind,default xyz)], values [(name,kind,default)], choices lists, outputs [(name,kind)]
# (header colour: the old types keep theirs)
N = [
 ('image','Texture Sample',1,[('UV',2,(0,0,0))],[('Image',2,0),('Size',0,1),('Sampler',1,0),('Wrap',6,0)],
   [['Colour','Data','Normal'],['Repeat','Clamp','Mirror']],[('Color',3),('R',1),('G',1),('B',1),('Alpha',1)]),
 ('noise','Noise Texture',1,[('Offset',2,(0,0,0))],[('Scale',0,4),('Detail',3,3),('Roughness',0,0.5)],[],[('Color',3)]),
 ('checker','Checker Texture',1,[('Color 1',3,(0.8,0.8,0.8)),('Color 2',3,(0.2,0.2,0.2))],[('Scale',0,2)],[],[('Color',3)]),
 ('gradient','Gradient Texture',1,[],[('Axis',1,1),('Scale',0,1),('Offset',0,0)],[['X','Y','Z','Radial','Spherical']],[('Color',3)]),
 ('mix','Mix',4,[('Factor',1,(0.5,0.5,0.5)),('Color 1',3,(0.8,0.8,0.8)),('Color 2',3,(0.2,0.2,0.2))],[('Mode',1,0)],[MIX],[('Color',3)]),
 ('ramp','Color Ramp',4,[('Factor',1,(0.5,0.5,0.5)),('Color 0',3,(0,0,0)),('Color 1',3,(1,1,1))],[('Position 0',0,0),('Position 1',0,1)],[],[('Color',3)]),
 ('math','Math',2,[('A',1,(0,0,0)),('B',1,(0,0,0)),('C',1,(0,0,0))],[('Operation',1,0)],[MATH_OPS],[('Value',1)]),
 ('bump','Bump',3,[('Height',1,(0,0,0))],[('Strength',0,1),('Distance',0,0.05)],[],[('Normal',2)]),
 ('normalmap','Normal Map',3,[('Color',3,(0.5,0.5,1))],[('Strength',0,1),('Green',1,0)],[['OpenGL (+Y)','DirectX (-Y)']],[('Normal',2)]),
 # new (M2)
 ('texcoord','Texture Coordinate',0,[],[('Tiling U',0,1),('Tiling V',0,1),('Offset U',0,0),('Offset V',0,0)],[],[('UV',2),('U',1),('V',1)]),
 ('position','Position',0,[],[('Space',1,0)],[['Object','World']],[('Position',2),('X',1),('Y',1),('Z',1)]),
 ('normal','Normal',0,[],[],[],[('Normal',2),('X',1),('Y',1),('Z',1)]),
 ('camera','Camera Vector',0,[],[],[],[('Vector',2)]),
 ('vcolor','Vertex Color',0,[],[],[],[('Color',3)]),
 ('time','Time',0,[],[('Speed',0,1)],[],[('Time',1)]),
 ('constant','Constant',0,[],[('Value',0,0.5)],[],[('Value',1)]),
 ('color','Color',0,[('Color',3,(0.8,0.8,0.8))],[],[],[('Color',3)]),
 ('fresnel','Fresnel',0,[('Normal',2,(0,0,0))],[('Exponent',0,5),('Base',0,0.04)],[],[('Fac',1)]),
 ('vmath','Vector Math',3,[('A',2,(0,0,0)),('B',2,(0,0,0)),('C',2,(0,0,0))],[('Operation',1,0)],[VMATH_OPS],[('Vector',2),('X',1),('Y',1),('Z',1)]),
 ('separate','Separate',3,[('Vector',2,(0,0,0))],[],[],[('X',1),('Y',1),('Z',1)]),
 ('combine','Combine',3,[('X',1,(0,0,0)),('Y',1,(0,0,0)),('Z',1,(0,0,0))],[],[],[('Vector',2)]),
 ('mapping','Mapping',3,[('Vector',2,(0,0,0)),('Offset',2,(0,0,0)),('Scale',2,(1,1,1))],[('Rotation',0,0)],[],[('Vector',2)]),
 ('panner','Panner',3,[('UV',2,(0,0,0)),('Time',1,(0,0,0))],[('Speed U',0,0.1),('Speed V',0,0)],[],[('UV',2)]),
 ('rotator','Rotator',3,[('UV',2,(0,0,0)),('Time',1,(0,0,0))],[('Centre U',0,0.5),('Centre V',0,0.5),('Speed',0,0.25)],[],[('UV',2)]),
 ('voronoi','Voronoi Texture',1,[('Vector',2,(0,0,0))],[('Scale',0,5),('Randomness',0,1),('Feature',1,0)],[['F1','F2','Edge']],[('Distance',1),('Color',3)]),
 ('hsv','Hue/Saturation',4,[('Color',3,(0.8,0.8,0.8))],[('Hue',0,0),('Saturation',0,1),('Value',0,1),('Factor',0,1)],[],[('Color',3)]),
 ('invert','Invert',4,[('Color',3,(0,0,0))],[('Factor',0,1)],[],[('Color',3)]),
 ('brightcon','Bright/Contrast',4,[('Color',3,(0.8,0.8,0.8))],[('Bright',0,0),('Contrast',0,0)],[],[('Color',3)]),
 ('desaturate','Desaturation',4,[('Color',3,(0.8,0.8,0.8))],[('Fraction',0,1)],[],[('Color',3)]),
 ('gamma','Gamma',4,[('Color',3,(0.8,0.8,0.8))],[('Gamma',0,1)],[],[('Color',3)]),
 ('blackbody','Blackbody',4,[],[('Kelvin',0,6500)],[],[('Color',3)]),
 ('brick','Brick Texture',1,[('Vector',2,(0,0,0)),('Brick',3,(0.6,0.25,0.15)),('Mortar',3,(0.8,0.8,0.8))],[('Scale',0,4),('Mortar',0,0.03),('Offset',0,0.5)],[],[('Color',3),('Fac',1)]),
 ('wave','Wave Texture',1,[('Vector',2,(0,0,0))],[('Scale',0,4),('Distortion',0,0),('Kind',1,0),('Axis',6,0)],[['Bands','Rings'],['X','Y','Z']],[('Fac',1),('Color',3)]),
 ('whitenoise','White Noise',1,[('Vector',2,(0,0,0))],[],[],[('Value',1),('Color',3)]),
 ('triplanar','Triplanar Sample',1,[],[('Image',2,0),('Size',0,1),('Sharpness',0,4),('Sampler',1,0)],[['Colour','Data']],[('Color',3),('Alpha',1)]),
 ('reroute','Reroute',5,[('In',3,(0,0,0))],[],[],[('Out',3)]),
 ('scalarparam','Scalar Parameter',6,[],[('Value',0,0.5),('Min',0,0),('Max',0,1)],[],[('Value',1)]),
 ('vectorparam','Vector Parameter',6,[],[('R',0,0.8),('G',0,0.8),('B',0,0.8)],[],[('Color',3)]),
 ('textureparam','Texture Parameter',6,[('UV',2,(0,0,0))],[('Image',2,0),('Size',0,1),('Sampler',1,0),('Wrap',6,0)],
   [['Colour','Data','Normal'],['Repeat','Clamp','Mirror']],[('Color',3),('R',1),('G',1),('B',1),('Alpha',1)]),
 ('fninput','Function Input',7,[('Preview',3,(0.5,0.5,0.5))],[('Input',1,0)],[['In 1','In 2','In 3']],[('Value',3)]),
 ('fnoutput','Function Output',7,[('Out 1',3,(0,0,0)),('Out 2',3,(0,0,0)),('Out 3',3,(0,0,0))],[],[],[]),
 ('fncall','Material Function',7,[('In 1',3,(0,0,0)),('In 2',3,(0,0,0)),('In 3',3,(0,0,0))],[('Function',4,0)],[],[('Out 1',3),('Out 2',3),('Out 3',3)]),
]
OLDCOL = {1:0x6b4f96,2:0x6b4f96,3:0x6b4f96,4:0x6b4f96,5:0x2f6589,6:0x2f6589,7:0x2f6589,8:0x6a3b63,9:0x6a3b63}

strs = {}
def S(t):
    if t not in strs: strs[t] = f'mns_{len(strs)}'
    return strs[t]
out = []
w = out.append
w('# ---- generated from the node list: names, titles, metadata, defaults ----')
w('.section .rodata'); w('.align 8')
w(f'.if MN_NTYPES - {len(N)}'); w(f'.error "MN_NTYPES at the top of matnodes.s must be {len(N)}"'); w('.endif')
w('graph_ntypes:   .long MN_NTYPES')
w('graph_type_names:')
for i in range(0, len(N), 6):
    w('                .quad ' + ', '.join(S(n[0]) for n in N[i:i+6]))
w('                .quad 0')
w('mn_titles:      .quad 0')
for i in range(0, len(N), 6):
    w('                .quad ' + ', '.join(S(n[1]) for n in N[i:i+6]))
w('# per type (as geonodes.s\'s gn_meta): input names (3), input kinds, value')
w('#   names (4), value kinds (0 number, 1 choice, 6 the second choice list,')
w('#   2 image, 3 whole number, 4 a function), the choices (lists one after the other: a')
w('#   count, then the names), output names (8), output kinds')
w('mn_meta:        .quad 0, 0, 0, 0, 0, 0, 0')
rows = []
for k, n in enumerate(N):
    name = n[0]
    ins = n[3] + [None]*(3-len(n[3])); vals = n[4] + [None]*(4-len(n[4]))
    outs = n[6] + [None]*(8-len(n[6]))
    w(f'                .quad mi_{name}, mik_{name}, mv_{name}, mvk_{name}, ' + (f'mc_{name}' if n[5] else '0') + f', mo_{name}, mok_{name}')
    rows.append(f'mi_{name}:' + ' '*max(1,15-len(name)-4) + '.quad ' + ', '.join(S(x[0]) if x else '0' for x in ins))
    rows.append(f'mv_{name}:' + ' '*max(1,15-len(name)-4) + '.quad ' + ', '.join(S(x[0]) if x else '0' for x in vals))
    rows.append(f'mo_{name}:' + ' '*max(1,15-len(name)-4) + '.quad ' + ', '.join(S(x[0]) if x else '0' for x in outs))
    if n[5]:
        parts = []
        for lst in n[5]:
            parts.append(f'{len(lst)}, ' + ', '.join(S(c) for c in lst))
        rows.append(f'mc_{name}:' + ' '*max(1,15-len(name)-4) + '.quad ' + ', '.join(parts))
for r in rows: w(r)
for n in N:
    name=n[0]
    ins = n[3] + [None]*(3-len(n[3])); vals = n[4] + [None]*(4-len(n[4])); outs = n[6] + [None]*(8-len(n[6]))
    w(f'mik_{name}:' + ' '*max(1,14-len(name)-4) + '.byte ' + ', '.join(str(x[1]) if x else '0' for x in ins))
    w(f'mvk_{name}:' + ' '*max(1,14-len(name)-4) + '.byte ' + ', '.join(str(x[1]) if x else '0' for x in vals))
    w(f'mok_{name}:' + ' '*max(1,14-len(name)-4) + '.byte ' + ', '.join(str(x[1]) if x else '0' for x in outs))
w('# header colours, categories (0 input, 1 texture, 2 math, 3 vector, 4 colour, 5 utility)')
w('.align 4')
w('mn_color:       .long 0')
for k, n in enumerate(N):
    col = OLDCOL.get(k+1, COLS[n[2]])
    w(f'                .long 0x{col:06x}               # {n[0]}')
w('mn_cat:         .byte 0, ' + ', '.join(str(n[2]) for n in N))
w('.align 8')
w('mn_cat_names:   .quad ' + ', '.join(S(c) for c in CAT) + ', 0')
w('# defaults per type: p0..p3, the inputs\' values (3 each)')
w('.align 4')
w('mn_defaults:')
for n in N:
    vals = [v[2] for v in n[4]] + [0]*(4-len(n[4]))
    ins = [list(i[2]) for i in n[3]] + [[0,0,0]]*(3-len(n[3]))
    flat = vals + [x for t in ins for x in t]
    w('    .float ' + ', '.join(repr(float(x)) for x in flat) + f'    # {n[0]}')
w('# the strings')
for t, l in strs.items():
    w(f'{l}:' + ' '*max(1,15-len(l)) + '.asciz "' + t + '"')
import os as _os
_p = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '..', 'src', 'matnodes.s')
_s = open(_p).read()
_i = _s.index('# ---- generated from the node list')
_j = _s.index('.section .note.GNU-stack')
open(_p, 'w').write(_s[:_i] + '\n'.join(out) + '\n\n' + _s[_j:])
print(len(N), 'types', len(strs), 'strings: src/matnodes.s')
