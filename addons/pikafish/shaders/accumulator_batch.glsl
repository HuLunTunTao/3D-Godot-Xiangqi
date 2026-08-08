#[compute]
#version 450

// Batched accumulator: computes acc[N * 2 * L1] for N positions in one dispatch.
// gid -> (position = gid / 1024, cell = gid % 1024). Active lists: [N * 260] ints.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) readonly buffer BiasBuf { int ft_bias[]; };
layout(set = 0, binding = 1) readonly buffer PsqWBuf { uint psq_w[]; };
layout(set = 0, binding = 2) readonly buffer ThreatWBuf { uint threat_w[]; };
layout(set = 0, binding = 3) readonly buffer ActvBuf { int actv[]; };
layout(set = 0, binding = 4) buffer AccBuf { int acc[]; };
layout(set = 0, binding = 5) readonly buffer ParamsBuf { int params[]; };  // [N]

const int L1 = 1024;

int ri8_psq(int idx) {
	uint w = psq_w[uint(idx) >> 2u];
	int b = int((w >> ((uint(idx) & 3u) * 8u)) & 0xFFu);
	return (b >= 128) ? b - 256 : b;
}
int ri8_thr(int idx) {
	uint w = threat_w[uint(idx) >> 2u];
	int b = int((w >> ((uint(idx) & 3u) * 8u)) & 0xFFu);
	return (b >= 128) ? b - 256 : b;
}

void main() {
	uint gid = gl_GlobalInvocationID.x;
	uint n = uint(params[0]);
	if (gid >= n * 1024u) return;
	uint pos = gid / 1024u;
	uint cell = gid % 1024u;
	int i = int(cell);
	int base = int(pos) * 260;

	int a0 = ft_bias[i];
	int p0c = actv[base + 0];
	for (int k = 0; k < p0c; k++) { a0 += ri8_psq(actv[base + 1 + k] * L1 + i); }
	int t0c = actv[base + 65];
	for (int k = 0; k < t0c; k++) { a0 += ri8_thr(actv[base + 66 + k] * L1 + i); }
	acc[int(pos) * 2048 + i] = a0;

	int a1 = ft_bias[i];
	int p1c = actv[base + 130];
	for (int k = 0; k < p1c; k++) { a1 += ri8_psq(actv[base + 131 + k] * L1 + i); }
	int t1c = actv[base + 195];
	for (int k = 0; k < t1c; k++) { a1 += ri8_thr(actv[base + 196 + k] * L1 + i); }
	acc[int(pos) * 2048 + 1024 + i] = a1;
}
