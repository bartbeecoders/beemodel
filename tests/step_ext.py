"""tests/step.py's other side: reads and writes STEP with an outside CAD
kernel. It runs inside FreeCAD (freecadcmd) or plain Python with the
OpenCASCADE bindings (OCP, from cadquery-ocp). Both are OpenCASCADE
underneath; FreeCAD's own readers and writers are the ones the issue asks
for.

The job comes in the environment, as freecadcmd passes no arguments:

  STEP_EXT_JOB   read  <in>          the solids: volume and centre of mass
                 copy  <in> <out>    read and write it again (assemblies,
                                     names and colours kept where it can)
                 nurbs <in> <out>    every face converted to a B-spline
  STEP_EXT_OUT   where to write the result lines:
                 "solid <volume> <cx> <cy> <cz>", "valid <0|1>", "ok"
"""
import os

JOB = os.environ['STEP_EXT_JOB'].split('\t')
OUT = os.environ['STEP_EXT_OUT']
lines = []

try:
    import FreeCAD  # noqa: F401
    import Part

    def read(path):
        return Part.read(path)

    def solids(shape):
        return [(s.Volume, s.CenterOfMass.x, s.CenterOfMass.y, s.CenterOfMass.z) for s in shape.Solids]

    def valid(shape):
        return shape.isValid()

    def copy(src, dst):
        # the assembly through FreeCAD's document (App::Part placements), the
        # plain shape if that is unavailable headless
        try:
            import Import
            doc = FreeCAD.newDocument('stepcopy')
            Import.insert(src, doc.Name)
            doc.recompute()
            Import.export([o for o in doc.RootObjects], dst)
            FreeCAD.closeDocument(doc.Name)
            if os.path.getsize(dst) > 0:
                return
        except Exception as e:  # noqa: BLE001
            lines.append('note document export failed: %s' % e)
        Part.read(src).exportStep(dst)

    def nurbs(src, dst):
        Part.read(src).toNurbs().exportStep(dst)

    lines.append('tool freecad %s' % '.'.join(FreeCAD.Version()[:3]))
except ImportError:
    from OCP.STEPControl import STEPControl_Reader, STEPControl_Writer, STEPControl_AsIs
    from OCP.STEPCAFControl import STEPCAFControl_Reader, STEPCAFControl_Writer
    from OCP.TDocStd import TDocStd_Document
    from OCP.TCollection import TCollection_ExtendedString
    from OCP.GProp import GProp_GProps
    from OCP.BRepGProp import BRepGProp
    from OCP.BRepCheck import BRepCheck_Analyzer
    from OCP.BRepBuilderAPI import BRepBuilderAPI_NurbsConvert
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopAbs import TopAbs_SOLID

    def read(path):
        r = STEPControl_Reader()
        r.ReadFile(path)
        r.TransferRoots()
        return r.OneShape()

    def solids(shape):
        out = []
        e = TopExp_Explorer(shape, TopAbs_SOLID)
        while e.More():
            p = GProp_GProps()
            BRepGProp.VolumeProperties_s(e.Current(), p)
            c = p.CentreOfMass()
            out.append((p.Mass(), c.X(), c.Y(), c.Z()))
            e.Next()
        return out

    def valid(shape):
        return BRepCheck_Analyzer(shape).IsValid()

    def copy(src, dst):
        doc = TDocStd_Document(TCollection_ExtendedString('doc'))
        r = STEPCAFControl_Reader()
        r.SetColorMode(True)
        r.SetNameMode(True)
        r.ReadFile(src)
        r.Transfer(doc)
        w = STEPCAFControl_Writer()
        w.Transfer(doc, STEPControl_AsIs)
        w.Write(dst)

    def nurbs(src, dst):
        w = STEPControl_Writer()
        w.Transfer(BRepBuilderAPI_NurbsConvert(read(src)).Shape(), STEPControl_AsIs)
        w.Write(dst)

    lines.append('tool ocp')

try:
    if JOB[0] == 'read':
        shape = read(JOB[1])
        for s in solids(shape):
            lines.append('solid %.17g %.17g %.17g %.17g' % s)
        lines.append('valid %d' % (1 if valid(shape) else 0))
    elif JOB[0] == 'copy':
        copy(JOB[1], JOB[2])
    elif JOB[0] == 'nurbs':
        nurbs(JOB[1], JOB[2])
    lines.append('ok')
except Exception as e:  # noqa: BLE001
    lines.append('error %s' % e)

with open(OUT, 'w') as f:
    f.write('\n'.join(lines) + '\n')
