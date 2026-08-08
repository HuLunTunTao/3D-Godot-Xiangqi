#[compute]
#version 450

// Forward + PSQT: reads acc[2*L1], computes positional network output, and sums
// PSQT from active feature lists. Final out = psqt/16 + positional/16.
// SqrClippedReLU uses wide multiply (matches Pikafish `(long long)y * y`).

// One position per 32-lane workgroup. Each lane owns one FC0/FC1 output.
layout(local_size_x = 32, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) readonly buffer AccBuf { int acc[]; };
layout(set = 0, binding = 1) readonly buffer Fc0wBuf { uint fc0_w[]; };
layout(set = 0, binding = 2) readonly buffer Fc0bBuf { int fc0_b[]; };
layout(set = 0, binding = 3) readonly buffer Fc1wBuf { uint fc1_w[]; };
layout(set = 0, binding = 4) readonly buffer Fc1bBuf { int fc1_b[]; };
layout(set = 0, binding = 5) readonly buffer Fc2wBuf { uint fc2_w[]; };
layout(set = 0, binding = 6) readonly buffer Fc2bBuf { int fc2_b[]; };
layout(set = 0, binding = 7) buffer OutBuf { int out_val[]; };
layout(set = 0, binding = 8) readonly buffer ActvBuf { int actv[]; };
layout(set = 0, binding = 9) readonly buffer PsqtBuf { int psqt[]; };          // [PSQ_DIM * 16]
layout(set = 0, binding = 10) readonly buffer ThreatPsqtBuf { int threat_psqt[]; }; // [THREAT_DIM * 16]
layout(set = 0, binding = 11) readonly buffer ParamsBuf { int params[]; };     // [bucket]

shared int tf[1024];
shared int y0[32];
shared int y1[32];
shared int c2[128];

int ri8_fc0(int idx) {
	uint w = fc0_w[uint(idx) >> 2u];
	int b = int((w >> ((uint(idx) & 3u) * 8u)) & 0xFFu);
	return (b >= 128) ? b - 256 : b;
}
int ri8_fc1(int idx) {
	uint w = fc1_w[uint(idx) >> 2u];
	int b = int((w >> ((uint(idx) & 3u) * 8u)) & 0xFFu);
	return (b >= 128) ? b - 256 : b;
}
int ri8_fc2(int idx) {
	uint w = fc2_w[uint(idx) >> 2u];
	int b = int((w >> ((uint(idx) & 3u) * 8u)) & 0xFFu);
	return (b >= 128) ? b - 256 : b;
}

// Match Pikafish SqrClippedReLU: min(127, ((long long)y * y) >> shift).
// Emulate 64-bit product with 32-bit parts (no int64 / double needed on Metal).
int sqr_clip(int y, int shift) {
	uint uy = uint(abs(y));
	uint lo = uy & 0xffffu;
	uint hi = uy >> 16u;
	uint ll = lo * lo;
	uint lh = lo * hi;
	uint hh = hi * hi;
	// product = hh<<32 + lh<<17 + ll  (since 2*lh << 16 = lh << 17)
	uint mid = lh << 1u;
	uint carry = 0u;
	uint low32 = ll + (mid << 16u);
	if (low32 < ll) carry = 1u;
	uint high32 = hh + (mid >> 16u) + carry;
	// Now (high32:low32) >> shift
	uint r;
	if (shift >= 32) {
		r = high32 >> uint(shift - 32);
	} else {
		r = (low32 >> uint(shift)) | (high32 << uint(32 - shift));
	}
	return int(min(127u, r));
}

int sum_psqt_persp(int base, int bucket) {
	int s = 0;
	int pc = actv[base];
	for (int k = 0; k < pc; k++) {
		s += psqt[actv[base + 1 + k] * 16 + bucket];
	}
	int tc = actv[base + 65];
	for (int k = 0; k < tc; k++) {
		s += threat_psqt[actv[base + 66 + k] * 16 + bucket];
	}
	return s;
}

void main() {
	uint lane = gl_LocalInvocationID.x;
	int bucket = params[0];

	for (int p = 0; p < 2; p++) {
		int off = 512 * p;
		int base = p * 1024;
		for (int j = int(lane); j < 512; j += 32) {
			int s0 = clamp(acc[base + j], 0, 255);
			int s1 = clamp(acc[base + j + 512], 0, 255);
			tf[off + j] = (s0 * s1) / 512;
		}
	}
	barrier();

	int o = int(lane);
	int s = fc0_b[o];
	int b = o * 1024;
	for (int i = 0; i < 1024; i++) s += tf[i] * ri8_fc0(b + i);
	y0[o] = s;
	barrier();

	int y = y0[o];
	c2[o] = sqr_clip(y, 21);
	c2[32 + o] = clamp(y >> 7, 0, 127);
	barrier();

	s = fc1_b[o];
	b = o * 64;
	for (int i = 0; i < 64; i++) s += c2[i] * ri8_fc1(b + i);
	y1[o] = s;
	barrier();

	y = y1[o];
	c2[64 + o] = sqr_clip(y, 19);
	c2[96 + o] = clamp(y >> 6, 0, 127);
	barrier();

	if (lane == 0u) {
		int y2 = fc2_b[0];
		for (int i = 0; i < 128; i++) y2 += c2[i] * ri8_fc2(i);

		int fwd = y2 + (y0[30] - y0[31]);
		int positional = (fwd * 9600) / 16384;
		int psqt_val = (sum_psqt_persp(0, bucket) - sum_psqt_persp(130, bucket)) / 2;
		// Keep separate /16 (toward zero) to match C++ / GDScript.
		out_val[0] = (psqt_val / 16) + (positional / 16);
	}
}
