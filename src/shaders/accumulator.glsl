#[compute]
#version 450

// Accumulator: computes acc[2 * L1] (i32) for both perspectives from active feature lists.
// Each invocation computes one output cell i for both perspectives.
// Weights (psq_w, threat_w) are uploaded as raw byte buffers; read 4 i8 per uint.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) readonly buffer BiasBuf { int ft_bias[]; };
layout(set = 0, binding = 1) readonly buffer PsqWBuf { uint psq_w[]; };
layout(set = 0, binding = 2) readonly buffer ThreatWBuf { uint threat_w[]; };
layout(set = 0, binding = 3) readonly buffer ActvBuf { int actv[]; };
// actv layout: [p0_psq_count, p0_psq[64], p0_thr_count, p0_thr[64],
//                p1_psq_count, p1_psq[64], p1_thr_count, p1_thr[64]]
layout(set = 0, binding = 4) buffer AccBuf { int acc[]; };

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
	uint gi = gl_GlobalInvocationID.x;
	if (gi >= 1024u) return;
	int i = int(gi);

	int a0 = ft_bias[i];
	int p0c = actv[0];
	for (int k = 0; k < p0c; k++) { a0 += ri8_psq(actv[1 + k] * L1 + i); }
	int t0c = actv[65];
	for (int k = 0; k < t0c; k++) { a0 += ri8_thr(actv[66 + k] * L1 + i); }
	acc[i] = a0;

	int a1 = ft_bias[i];
	int p1c = actv[130];
	for (int k = 0; k < p1c; k++) { a1 += ri8_psq(actv[131 + k] * L1 + i); }
	int t1c = actv[195];
	for (int k = 0; k < t1c; k++) { a1 += ri8_thr(actv[196 + k] * L1 + i); }
	acc[1024 + i] = a1;
}
