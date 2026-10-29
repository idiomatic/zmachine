import sys, subprocess, itertools, importlib.util

# play.py <plan.py> <seed> <out>: play a plan step by step for one seed; each step may get waits before it
# when its check fails, backtracking a step when no number of waits helps; writes the command list.
# Run from the repository root after `zig build` and `zig build stories`.
Z = 'zig-out/bin/zmachine'
spec = importlib.util.spec_from_file_location('plan', sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
seed = sys.argv[2]; STORY = mod.STORY
BAD = ('You have died', 'disappear', 'tipped it over', 'headlong', 'rusty. Try again')
D8 = ['north', 'northeast', 'east', 'southeast', 'south', 'southwest', 'west', 'northwest']
runs = 0

def play(lines):
    global runs; runs += 1
    out = subprocess.run([Z, '--seed', seed, STORY], input='\n'.join(lines) + '\n',
                         capture_output=True, text=True).stdout
    return out.split('\n>')

def tail(blocks, n):
    return '\n'.join(blocks[-n - 1:-1])

def attempt(lines, step):
    # Returns the commands this step adds, or None.
    kind = step[0]
    if kind == 'do':
        cmds, want = step[1], step[2]
        t = tail(play(lines + cmds), len(cmds))
        ok = all(w in t for w in (want if isinstance(want, tuple) else (want,))) and not any(b in t for b in BAD)
        return cmds if ok else None
    if kind == 'go':  # leave the carousel for a room
        for d in D8:
            t = tail(play(lines + [d]), 1)
            if f'\n{step[1]}\n' in '\n' + t.split('\n', 1)[-1] + '\n' and not any(b in t for b in BAD):
                return [d]
        return None
    if kind == 'until':  # repeat cmds up to n times until want appears
        cmds, want, n = step[1], step[2], step[3]
        acc = []
        for _ in range(n):
            acc += cmds
            t = tail(play(lines + acc), len(acc))
            if any(b in t for b in BAD): return None
            if want in t: return acc
        return None
    if kind == 'odd':  # follow the window's glow until the floor swings open, then find the way down
        L = ['dark.', 'flickering dimly.', 'dimly glowing.', 'glowing.', 'glowing brightly.', 'glowing serenely.']
        def lvl(p):
            t = play(lines + p)[-2]
            if 'rusty squeal' in t: return 9
            return max([i for i, w in enumerate(L) if 'which is ' + w in t] or [-1])
        path, cur = [], lvl([])
        for _ in range(10):
            if cur == 9: break
            found = None
            for n in (1, 2):
                for m in itertools.product(D8, repeat=n):
                    v = lvl(path + list(m))
                    if v > cur: found, cur = path + list(m), v; break
                if found: break
            if not found: return None
            path = found
        if cur != 9: return None
        for d in D8:
            if 'Cerberus' in tail(play(lines + path + [d, 'down']), 1): return path + [d, 'down']
        return None
    raise ValueError(kind)

def solve(steps, maxwait=4):
    lines, i, waits, hist = [], 0, [0] * len(steps), []
    while i < len(steps):
        add = None
        while waits[i] <= maxwait:
            add = attempt(lines + ['wait'] * waits[i], steps[i])
            if add is not None: break
            waits[i] += 1
        if add is None:
            if not hist: return None
            waits[i] = 0; i -= 1; lines = hist.pop(); waits[i] += 1
            continue
        hist.append(lines); lines = lines + ['wait'] * waits[i] + add; i += 1
        print(f'step {i}/{len(steps)} ok ({len(lines)} lines, {runs} runs)', file=sys.stderr, flush=True)
    return lines

lines = solve(mod.STEPS)
if lines is None: sys.exit('no solution')
open(sys.argv[3], 'w').write('\n'.join(lines) + '\n')
print(len(lines), 'lines')
