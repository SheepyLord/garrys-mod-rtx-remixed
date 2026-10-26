"""Fit the wave solver's vertical-derivative kernel (source/rtx_water/wavesim.cpp).

The solver integrates Tessendorf's iWave equation, with a spring added,

    d2h/dt2 + alpha dh/dt = -(g sqrt(-laplacian) + beta) (h + head)

on a grid of cells D game units wide. sqrt(-laplacian) is a convolution with a
radial kernel; Tessendorf builds it from a Gaussian-smoothed Bessel integral and
normalises its centre to 1. In physical units that kernel is far off (waves of 4
cells move at half their real speed, long ones up to 90 % too fast, and its taps do
not sum to zero). Here the kernel is fitted instead, by least squares, so that a
plane wave of wavenumber k gets g R(k) + beta = g |k|: deep-water gravity waves,
omega^2 = g k, the dispersion that gives water its look (rings that spread into
trains, Kelvin wakes). A kernel a few cells wide cannot follow |k| down to the
longest waves (its response there grows like k^2, so long waves travel too slowly);
the spring beta supplies part of what it lacks there. The taps sum to zero (no
volume is created) and g R + beta never goes negative (the explicit step is stable).

    python fit_wave_kernel.py         prints the C++ table and the phase-speed check

1 unit = 1 inch, so g = 386 units/s^2.
"""
import numpy as np

D = 4.0          # cell size, units (must match wavesim.h)
P = 6            # kernel radius, cells
G = 386.0
SPRING = 10.0    # beta, 1/s^2 (kSpring in wavesim.cpp)
STEP = 1 / 60.0  # time step, s (kStep)
DAMPING = 0.35   # alpha, 1/s (Settings::damping), for the phase-speed check


def offsets(P):
    """Unique offsets (a >= b >= 0) inside the circle of radius P + 0.5."""
    return [(a, b) for a in range(P + 1) for b in range(a + 1) if a * a + b * b <= (P + 0.5) ** 2]


def mask(P, a, b):
    n = 2 * P + 1
    m = np.zeros((n, n))
    for sa, sb in {(a, b), (b, a)}:
        for s1 in (-1, 1):
            for s2 in (-1, 1):
                m[P + s1 * sa, P + s2 * sb] = 1
    return m


def response(K, kx, ky):
    P = (K.shape[0] - 1) // 2
    off = np.arange(-P, P + 1) * D
    ph = np.cos(kx[:, None, None] * off[None, :, None] + ky[:, None, None] * off[None, None, :])
    return (K[None] * ph).sum((1, 2))


def target(kmag):
    """|k| less what the spring gives, rolled off towards the grid's resolution limit
    (those waves are noise)."""
    kd = kmag * D
    return np.maximum(kmag * np.exp(-np.maximum(kd - 2.4, 0) ** 2 * 2) - SPRING / G, 0.0)


def fit():
    offs = offsets(P)
    masks = [mask(P, a, b) for a, b in offs]
    # the whole frequency zone: by symmetry the triangle 0 <= ky <= kx <= pi / D
    g = np.linspace(0, np.pi, 90) / D
    KX, KY = np.meshgrid(g, g)
    keep = KY <= KX
    kx, ky = KX[keep], KY[keep]
    kmag = np.hypot(kx, ky)
    A = np.stack([response(m, kx, ky) for m in masks], 1)
    t = target(kmag)
    kd = kmag * D
    # relative error inside the band that carries visible waves, looser outside it
    w = np.where((kd >= 0.12) & (kd <= 2.3), 1.0, 0.3) / np.maximum(kmag, 0.03 / D)
    sums = np.array([m.sum() for m in masks])
    floor_rows, floor_t = [], []
    for _ in range(12):
        A2 = np.vstack([A * w[:, None], 1e4 * sums[None, :]] + floor_rows)
        t2 = np.concatenate([t * w, [0.0]] + floor_t)
        c, *_ = np.linalg.lstsq(A2, t2, rcond=None)
        R = A @ c
        bad = R < 0.03 * t + 1e-5 - SPRING / G * 0.5
        if not bad.any():
            break
        # pull the response up where it dips below a small fraction of the target
        floor_rows.append(A[bad] * 50.0)
        floor_t.append(np.maximum(0.05 * t[bad], 1e-4) * 50.0)
    return offs, c, sum(ci * m for ci, m in zip(c, masks))


def stepped_speed(K, lam, angle=0.0):
    """Phase speed of a plane wave as the solver steps it (damping and spring included)."""
    k = 2 * np.pi / lam
    r = response(K, np.array([k * np.cos(angle)]), np.array([k * np.sin(angle)]))[0]
    ad = DAMPING * STEP
    c2 = 1 / (1 + ad)
    # free waves: h+ = h + c2 (h - h-) - c2 dt^2 (g r + beta) h
    a = 1 + c2 - c2 * STEP * STEP * (G * r + SPRING)
    rho = np.roots([1, -a, c2])
    return abs(np.angle(rho[0])) / STEP / k


def main():
    offs, c, K = fit()
    g = np.linspace(0, np.pi, 181) / D
    KX, KY = np.meshgrid(g, g)
    R = response(K, KX.ravel(), KY.ravel())
    worst, peak = (G * R + SPRING).min(), (G * R + SPRING).max()
    print(f"// {len(offs)} radial taps, radius {P} cells of {D:g} units; taps sum {K.sum():+.1e}")
    print(f"// g R + beta over the whole zone: min {worst:+.2f}, max {peak:.1f} per s^2 "
          f"(stable for time steps below {2 / np.sqrt(peak):.3f} s)")
    print("constexpr KernelTap kKernel[] = {")
    for (a, b), v in zip(offs, c):
        print(f"\t{{ {a}, {b}, {v:+.9e}f }},")
    print("};")
    print()
    for lam in (8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256):
        c_sim, c_diag = stepped_speed(K, lam), stepped_speed(K, lam, np.pi / 4)
        c_real = np.sqrt(G * lam / (2 * np.pi))
        print(f"// wavelength {lam:4d}: {c_sim:6.1f} units/s (deep water {c_real:6.1f}) "
              f"{100 * (c_sim / c_real - 1):+5.1f} %, diagonal {100 * (c_diag / c_real - 1):+5.1f} %")


if __name__ == "__main__":
    main()
