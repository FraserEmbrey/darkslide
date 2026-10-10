#!/usr/bin/env python3
"""
Translates darktable's OpenCL C kernels (data/kernels/*.cl) to Metal Shading
Language, so the same kernels can run through a Metal backend behind
darktable's dt_opencl_* interface.

usage: cl2metal.py KERNEL_DIR OUT_DIR
Writes OUT_DIR/<name>.metal and OUT_DIR/<name>.json (argument map per kernel:
for each OpenCL argument index, whether it is a texture, buffer, threadgroup
buffer or scalar, and its Metal slot). The host side needs the map because
Metal binds textures, buffers and scalars in separate slot spaces.

Approach: OpenCL C and MSL are close; the differences are handled by
  - a compatibility header (cl_compat.h) for built-ins, samplers, images, atomics
  - rewriting OpenCL vector literals "(float4)(a,b,c,d)" to "float4(a,b,c,d)"
  - rewriting kernel signatures to Metal argument attributes
  - inlining #include "xxx.h" (runtime Metal compilation has no file system)
"""
import json
import os
import re
import sys

VEC = r'(?:u?char|u?short|u?int|u?long|float|half|double)(?:2|3|4|8|16)?'

def strip_comments(src):
    src = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n'), src, flags=re.S)
    return re.sub(r'//[^\n]*', '', src)

def inline_includes(src, kdir, seen):
    def rep(m):
        name = m.group(1)
        if name in seen:
            return ''
        seen.add(name)
        path = os.path.join(kdir, name)
        if not os.path.exists(path):
            return m.group(0)
        return inline_includes(strip_comments(open(path).read()), kdir, seen)
    return re.sub(r'#\s*include\s*"([^"]+)"', rep, src)

def split_args(s):
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch in '(<[': depth += 1
        if ch in ')>]': depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur); cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [a.strip() for a in out]

def translate_arg(arg, body, slots):
    """returns (metal argument, arg map entry, prologue line for the body)"""
    a = re.sub(r'\s+', ' ', arg.replace('__', '')).strip()
    # pointer to array, e.g. "global const unsigned char (*const xtrans)[6]":
    # bind a plain buffer and rebuild the typed pointer in the kernel body
    pa = re.match(r'(.*?)\(\s*\*\s*(?:const\s*)?(\w+)\s*\)\s*((?:\[\d+\])*)$', a)
    if pa:
        base, name, dims = pa.group(1).strip(), pa.group(2), pa.group(3)
        base = re.sub(r'\bglobal\b', 'device', base)
        if 'device' not in base and 'constant' not in base:
            base = 'device ' + base
        slot = slots['buffer']; slots['buffer'] += 1
        cast = f'({base} (*){dims})' if dims else f'({base} *)'
        decl = f'{base} (*const {name}){dims}' if dims else f'{base} *const {name}'
        return (f'{base} *{name}__flat [[buffer({slot})]]', {'kind': 'buffer', 'slot': slot},
                f'{decl} = {cast}{name}__flat;')
    name = re.findall(r'(\w+)\s*$', a)[0]
    if 'image2d_t' in a:
        write = 'write_only' in a
        # element type: unsigned images are read with read_imageui
        kind = 'uint' if re.search(r'(?:read|write)_imageui\s*\(\s*' + name + r'\b', body) else 'float'
        access = 'access::write' if write else 'access::sample'
        slot = slots['texture']; slots['texture'] += 1
        return f'texture2d<{kind}, {access}> {name} [[texture({slot})]]', {'kind': 'texture', 'slot': slot, 'write': write}, None
    if '*' in a:
        if re.match(r'(const )?local\b', a) or ' local ' in f' {a} ':
            t = re.sub(r'\blocal\b', 'threadgroup', a)
            slot = slots['threadgroup']; slots['threadgroup'] += 1
            return f'{t} [[threadgroup({slot})]]', {'kind': 'local', 'slot': slot}, None
        t = re.sub(r'\bglobal\b', 'device', a)
        if 'device' not in t and 'constant' not in t:
            t = 'device ' + t
        slot = slots['buffer']; slots['buffer'] += 1
        return f'{t} [[buffer({slot})]]', {'kind': 'buffer', 'slot': slot}, None
    # scalar or vector passed by value: packed into the kernel's argument struct
    # (one setBytes call, and no risk of passing Metal's 31 buffer slots)
    t = re.sub(r'\bconst\b', '', a).strip()
    typ = t[: t.rfind(name)].strip()
    slots['scalars'].append((typ, name))
    return None, {'kind': 'scalar', 'field': len(slots['scalars']) - 1, 'type': typ}, f'const {typ} {name} = __args.{name};'

def translate_kernels(src):
    argmaps = {}
    out, pos = [], 0
    for m in re.finditer(r'\b(?:__)?kernel\s+void\s+(\w+)\s*\(', src):
        start, name = m.end(), m.group(1)
        depth, i = 1, start
        while depth:
            depth += {'(': 1, ')': -1}.get(src[i], 0); i += 1
        args = split_args(src[start:i - 1])
        nxt = re.search(r'\n\s*(?:__)?kernel\s+void', src[i:])
        body_end = i + nxt.start() if nxt else -1
        body = src[i:body_end if body_end > 0 else len(src)]
        # buffer slot 0 is the argument struct
        slots = {'texture': 0, 'buffer': 1, 'threadgroup': 0, 'scalars': []}
        new_args, amap, prologue = [], [], []
        for a in args:
            t, info, pro = translate_arg(a, body, slots)
            if t: new_args.append(t)
            amap.append(info)
            if pro: prologue.append(pro)
        struct = ''
        if slots['scalars']:
            fields = ' '.join(f'{typ} {n};' for typ, n in slots['scalars'])
            struct = f'struct __args_{name} {{ {fields} }};\n'
            new_args.insert(0, f'constant __args_{name} &__args [[buffer(0)]]')
        new_args.append('uint3 __gid [[thread_position_in_grid]], uint3 __lid [[thread_position_in_threadgroup]], '
                        'uint3 __lsz [[threads_per_threadgroup]], uint3 __grp [[threadgroup_position_in_grid]], '
                        'uint3 __gsz [[threads_per_grid]], uint3 __ngr [[threadgroups_per_grid]]')
        argmaps[name] = amap
        out.append(src[pos:m.start()])
        out.append(struct + f'kernel void {name}(' + ',\n    '.join(new_args) + ')')
        pos = i
        if prologue:
            brace = src.index('{', i)
            out.append(src[i:brace + 1] + '\n  ' + '\n  '.join(prologue))
            pos = brace + 1
    out.append(src[pos:])
    return ''.join(out), argmaps

def qualify_helper_params(src):
    """In OpenCL C an unqualified pointer parameter means private memory;
    Metal wants that spelled out. Arrays as parameters decay to such pointers."""
    def fix_params(m):
        # skip kernels, and control statements that look like definitions ("else if (...) {")
        if re.search(r'\b(kernel|if|while|for|switch|return|else|do)\s*$', m.group(1)) or \
           re.search(r'\b(kernel|else)\b', m.group(1)):
            return m.group(0)
        params = split_args(m.group(2))
        fixed = []
        for p in params:
            q = p
            arr = re.match(r'(.*?\b)(\w+)\s*\[\s*\w*\s*\]$', p)
            if arr and '(' not in p:
                q = f'{arr.group(1)}*{arr.group(2)}'
            if '*' in q and not re.search(r'\b(device|constant|threadgroup|thread|global|local|__global|__local|__constant)\b', q):
                q = 'thread ' + q
            fixed.append(q)
        return m.group(1) + '(' + ', '.join(fixed) + ')' + m.group(3)
    return re.sub(r'((?:^|\n)[ \t]*(?:static\s+)?(?:inline\s+)?(?:const\s+)?[\w]+\s+\w+\s*)\(([^;{}()]*(?:\([^()]*\)[^;{}()]*)*)\)(\s*\{)',
                  fix_params, src)

def enums_as_int(src):
    """OpenCL C converts int to enum implicitly, C++ doesn't: keep the
    enumerators but make the typedef'd enum types plain ints."""
    return re.sub(r'typedef\s+enum\s*(\w*)\s*\{([^}]*)\}\s*(\w+)\s*;',
                  lambda m: f'enum {{{m.group(2)}}};\ntypedef int {m.group(3)};', src)

def translate(path, kdir):
    src = strip_comments(open(path).read())
    src = inline_includes(src, kdir, set())
    src = enums_as_int(src)
    src, argmaps = translate_kernels(src)
    src = qualify_helper_params(src)
    # vector literals and casts: (float4)(a, b) -> float4(a, b); (int)(x) -> int(x).
    # A const qualifier is dropped too: left as a C++ cast, (const float4)(a, b, c, d)
    # would apply the comma operator and broadcast d
    src = re.sub(r'\(\s*(?:const\s+)?(' + VEC + r')\s*\)\s*\(', r'\1(', src)
    # images passed to helper functions (kernel arguments are already done)
    src = re.sub(r'\b(?:__)?write_only\s+image2d_t\b', 'texture2d<float, access::write>', src)
    src = re.sub(r'\b(?:(?:__)?read_only\s+)?image2d_t\b', 'texture2d<float, access::sample>', src)
    # OpenCL component names: v.s0 -> v.x, v.s012 -> v.xyz, .lo/.hi on 4-vectors
    src = re.sub(r'\.s([0-3]+)\b', lambda m: '.' + ''.join('xyzw'[int(c)] for c in m.group(1)), src)
    src = re.sub(r'\.lo\b', '.xy', src)
    src = re.sub(r'\.hi\b', '.zw', src)
    # Linear-filtered reads stay on the hardware filter: darktable's OpenCL path
    # on Apple GPUs uses it too, and an exact blend (read_imagef_linear in
    # cl_compat.h) moved further from it, not closer.
    # address spaces outside kernel signatures
    src = re.sub(r'\b__global\b|\bglobal\b(?!\s*\()', 'device', src)
    src = re.sub(r'\b__local\b|\blocal\b(?=\s+\w)', 'threadgroup', src)
    src = re.sub(r'\b__constant\b', 'constant', src)
    src = re.sub(r'\b(__)?(read_only|write_only|read_write)\b', '', src)
    # samplers are constexpr in Metal; their OpenCL definitions are replaced by the compat header
    src = re.sub(r'constant\s+sampler_t\s+\w+\s*=[^;]*;', '', src)
    return '#include "cl_compat.h"\n' + src, argmaps

# ---- compiler-guided fix-ups ------------------------------------------------
# Some differences depend on expression types, which only the compiler knows.
# compile-test.swift --json reports errors with line and column; these rewrite
# exactly those places.

def _line_offset(text, line, col):
    starts = [0] + [i + 1 for i, c in enumerate(text) if c == '\n']
    return starts[line - 1] + col - 1

def _ternary_to_select(text, q):
    """rewrite the ternary whose '?' is at q as select(false, true, cond)"""
    # condition: back to the enclosing '(' or an expression boundary
    i, depth = q - 1, 0
    while i >= 0:
        c = text[i]
        if c in ')]': depth += 1
        elif c in '([':
            if depth == 0: break
            depth -= 1
        elif depth == 0 and c in ';{},': break
        # an assignment ends the condition; the '=' of <=, >=, == and != doesn't
        elif depth == 0 and c == '=' and text[i - 1] not in '<>=!' and text[i + 1] != '=': break
        elif depth == 0 and text[i - 6:i + 1] == 'return ': break
        i -= 1
    cstart = i + 1
    # true branch: to the matching ':' at depth 0 (skipping nested ternaries)
    j, depth, nested = q + 1, 0, 0
    while True:
        c = text[j]
        if c in '([': depth += 1
        elif c in ')]': depth -= 1
        elif c == '?' and depth == 0: nested += 1
        elif c == ':' and depth == 0:
            if nested == 0: break
            nested -= 1
        j += 1
    colon = j
    # false branch: to ')' closing the enclosing group, or ',' / ';' at depth 0
    k, depth = colon + 1, 0
    while True:
        c = text[k]
        if c in '([': depth += 1
        elif c in ')]':
            if depth == 0: break
            depth -= 1
        elif depth == 0 and c in ',;': break
        k += 1
    cond, a, b = text[cstart:q].strip(), text[q + 1:colon].strip(), text[colon + 1:k].strip()
    return text[:cstart] + f' select({b}, {a}, {cond})' + text[k:]

def apply_fixups(outdir, errors_path):
    errors = json.load(open(errors_path))
    by_file = {}
    for e in errors:
        by_file.setdefault(e['file'], []).append(e)
    changed = 0
    for f, errs in by_file.items():
        path = os.path.join(outdir, f)
        text = open(path).read()
        # bottom-up so earlier offsets stay valid
        for e in sorted(errs, key=lambda e: (e['line'], e['col']), reverse=True):
            off = _line_offset(text, e['line'], e['col'])
            if 'vector condition type' in e['message']:
                q = text.find('?', off)
                if q >= 0:
                    text = _ternary_to_select(text, q); changed += 1
            elif 'cannot be narrowed from type' in e['message']:
                # brace initialisers: cast to the element type the compiler names
                m = re.search(r"to '([\w ]+)' in initializer list", e['message'])
                end, depth = off, 0
                while text[end] not in ',}' or depth:
                    depth += {'(': 1, ')': -1}.get(text[end], 0); end += 1
                if m:
                    text = text[:off] + f'({m.group(1)})(' + text[off:end] + ')' + text[end:]; changed += 1
            elif 'converts between mismatching address spaces' in e['message']:
                m = re.search(r"from '(?:const )?(device|constant|threadgroup|thread)\b", e['message'])
                p = text.find('(', off)
                if m and p >= 0:
                    text = text[:p + 1] + m.group(1) + ' ' + text[p + 1:]; changed += 1
            elif 'explicit address space qualifier' in e['message']:
                # point at the start of the type, then mark it as private memory
                start = off
                while start > 0 and (text[start - 1].isalnum() or text[start - 1] == '_'): start -= 1
                if not re.match(r'\s*(device|constant|threadgroup|thread)\b', text[max(0, start - 12):start][::-1][::-1][-12:]):
                    text = text[:start] + 'thread ' + text[start:]; changed += 1
        open(path, 'w').write(text)
    return changed

def main():
    if sys.argv[1] == '--fixup':
        print(apply_fixups(sys.argv[2], sys.argv[3]), 'fix-ups applied')
        return
    kdir, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    compat = open(os.path.join(os.path.dirname(__file__), 'cl_compat.h')).read()
    for f in sorted(os.listdir(kdir)):
        if not f.endswith('.cl'):
            continue
        metal, argmaps = translate(os.path.join(kdir, f), kdir)
        metal = metal.replace('#include "cl_compat.h"\n', compat + '\n')   # runtime compiles take one string
        base = f[:-3]
        open(os.path.join(outdir, base + '.metal'), 'w').write(metal)
        json.dump(argmaps, open(os.path.join(outdir, base + '.json'), 'w'), indent=1)

if __name__ == '__main__':
    main()
