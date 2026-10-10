// cl_compat.h: OpenCL C built-ins in Metal Shading Language, for darktable's
// kernels translated by cl2metal.py. Prepended to every translated file.
#include <metal_stdlib>
using namespace metal;

// work-item functions; __gid and friends are added to every kernel's arguments
#define get_global_id(d)   ((int)__gid[d])
#define get_local_id(d)    ((int)__lid[d])
#define get_local_size(d)  ((int)__lsz[d])
#define get_group_id(d)    ((int)__grp[d])
#define get_global_size(d) ((int)__gsz[d])
#define get_num_groups(d)  ((int)__ngr[d])
#define CLK_LOCAL_MEM_FENCE  1
#define CLK_GLOBAL_MEM_FENCE 2
#define barrier(f) threadgroup_barrier((f) & CLK_GLOBAL_MEM_FENCE ? mem_flags::mem_device : mem_flags::mem_threadgroup)
#define mem_fence(f) threadgroup_barrier(mem_flags::mem_device)

// darktable's four samplers, all in pixel coordinates (OpenCL "normalized false")
constexpr sampler sampleri(coord::pixel, address::clamp_to_edge, filter::nearest);
constexpr sampler samplerf(coord::pixel, address::clamp_to_edge, filter::linear);
constexpr sampler samplerc(coord::pixel, address::clamp_to_zero, filter::nearest);
constexpr sampler samplerA(coord::pixel, address::clamp_to_edge, filter::nearest);
#define sampler_t sampler

// images. OpenCL reads integer coordinates at the pixel; Metal samples at
// pixel centres, hence the +0.5. Integer textures can't be filtered, so they
// are read with an explicit clamp to edge.
static inline float4 read_imagef(texture2d<float, access::sample> t, sampler s, int2 c)  { return t.sample(s, float2(c) + 0.5f); }
static inline float4 read_imagef(texture2d<float, access::sample> t, sampler s, float2 c) { return t.sample(s, c); }
// darktable's linear sampler, blended in full precision: the hardware filter
// computes its weights at lower precision, which shifted results by up to 0.5%
static inline float4 read_imagef_linear(texture2d<float, access::sample> t, float2 c)
{
  const float2 p = c - 0.5f;
  const float2 f = p - floor(p);
  const int2 i = int2(floor(p));
  const int2 m = int2(t.get_width() - 1, t.get_height() - 1);
  const float4 a = t.read(uint2(clamp(i, int2(0), m)));
  const float4 b = t.read(uint2(clamp(i + int2(1, 0), int2(0), m)));
  const float4 d = t.read(uint2(clamp(i + int2(0, 1), int2(0), m)));
  const float4 e = t.read(uint2(clamp(i + int2(1, 1), int2(0), m)));
  return mix(mix(a, b, f.x), mix(d, e, f.x), f.y);
}
static inline uint4 read_imageui(texture2d<uint, access::sample> t, sampler s, int2 c)
{
  const int2 m = int2(t.get_width() - 1, t.get_height() - 1);
  return t.read(uint2(clamp(c, int2(0), m)));
}
// OpenCL drops writes outside the image; on Metal they're undefined and can
// land inside it (darktable's highlights laplacian writes a full-size grid
// into a downscaled image), so they are checked
static inline bool __in_image(int2 c, uint w, uint h) { return uint(c.x) < w && uint(c.y) < h; }
static inline void write_imagef(texture2d<float, access::write> t, int2 c, float4 v)
{
  if(__in_image(c, t.get_width(), t.get_height())) t.write(v, uint2(c));
}
static inline void write_imageui(texture2d<uint, access::write> t, int2 c, uint4 v)
{
  if(__in_image(c, t.get_width(), t.get_height())) t.write(v, uint2(c));
}
template<typename T, access A> static inline int get_image_width(texture2d<T, A> t)  { return t.get_width(); }
template<typename T, access A> static inline int get_image_height(texture2d<T, A> t) { return t.get_height(); }
#define CLK_NORMALIZED_COORDS_FALSE 0
#define CLK_ADDRESS_CLAMP_TO_EDGE 0
#define CLK_ADDRESS_CLAMP 0
#define CLK_ADDRESS_NONE 0
#define CLK_FILTER_NEAREST 0
#define CLK_FILTER_LINEAR 0

// maths: native_ and half_ variants map to Metal's fast versions
#define native_sin(x)   fast::sin(x)
#define native_cos(x)   fast::cos(x)
#define native_tan(x)   fast::tan(x)
#define native_exp(x)   fast::exp(x)
#define native_exp2(x)  fast::exp2(x)
#define native_log(x)   fast::log(x)
#define native_log2(x)  fast::log2(x)
#define native_log10(x) fast::log10(x)
#define native_sqrt(x)  fast::sqrt(x)
#define native_rsqrt(x) fast::rsqrt(x)
#define native_powr(a, b) fast::powr(a, b)
#define native_recip(x) (1.0f / (x))
#define native_divide(a, b) ((a) / (b))
#define half_exp(x) fast::exp(x)
#define half_log(x) fast::log(x)
#define half_sqrt(x) fast::sqrt(x)
#define half_powr(a, b) fast::powr(a, b)
#define mad(a, b, c) fma(a, b, c)
template<typename T> static inline T hypot(T x, T y) { return sqrt(x * x + y * y); }
template<typename T> static inline T cbrt(T x) { return sign(x) * pow(abs(x), T(1.0f / 3.0f)); }
#define native_exp10(x) fast::exp10(x)
template<typename T> static inline T log1p(T x) { return log(T(1) + x); }
#define fast_length(x) fast::length(x)
#define fast_normalize(x) fast::normalize(x)
#define mad24(a, b, c) ((a) * (b) + (c))
#define mul24(a, b) ((a) * (b))
// OpenCL's two-argument fract also returns the integer part
template<typename T> static inline T fract(T x, thread T *i) { *i = floor(x); return fract(x); }

// reinterpretation and conversion
#define as_float(x)  as_type<float>(x)
#define as_float2(x) as_type<float2>(x)
#define as_float4(x) as_type<float4>(x)
#define as_int(x)    as_type<int>(x)
#define as_int2(x)   as_type<int2>(x)
#define as_int4(x)   as_type<int4>(x)
#define as_uint(x)   as_type<uint>(x)
#define as_uint4(x)  as_type<uint4>(x)
#define convert_int(x)    int(x)
#define convert_int2(x)   int2(x)
#define convert_int3(x)   int3(x)
#define convert_int4(x)   int4(x)
#define convert_uint(x)   uint(x)
#define convert_uint4(x)  uint4(x)
#define convert_float(x)  float(x)
#define convert_float2(x) float2(x)
#define convert_float3(x) float3(x)
#define convert_float4(x) float4(x)
#define convert_int_rtz(x) int(trunc(x))
#define convert_int_rte(x) int(rint(x))
#define convert_int2_rte(x) int2(rint(x))
#define convert_int4_rte(x) int4(rint(x))

// vector loads and stores from buffers
template<typename P> static inline float2 vload2(size_t i, P p) { return float2(p[2*i], p[2*i+1]); }
template<typename P> static inline float4 vload4(size_t i, P p) { return float4(p[4*i], p[4*i+1], p[4*i+2], p[4*i+3]); }
template<typename V, typename P> static inline void vstore2(V v, size_t i, P p) { p[2*i] = v.x; p[2*i+1] = v.y; }
template<typename V, typename P> static inline void vstore4(V v, size_t i, P p) { p[4*i] = v.x; p[4*i+1] = v.y; p[4*i+2] = v.z; p[4*i+3] = v.w; }
template<typename P> static inline float vload_half(size_t i, P p) { return float(p[i]); }
template<typename P> static inline float4 vload_half4(size_t i, P p) { return float4(p[4*i], p[4*i+1], p[4*i+2], p[4*i+3]); }
template<typename P> static inline void vstore_half(float v, size_t i, P p) { p[i] = half(v); }
template<typename P> static inline void vstore_half4(float4 v, size_t i, P p) { p[4*i] = half(v.x); p[4*i+1] = half(v.y); p[4*i+2] = half(v.z); p[4*i+3] = half(v.w); }

// 32-bit integer atomics, OpenCL 1.x style
static inline int atomic_add(volatile device int *p, int v) { return atomic_fetch_add_explicit((volatile device atomic_int *)p, v, memory_order_relaxed); }
static inline uint atomic_add(volatile device uint *p, uint v) { return atomic_fetch_add_explicit((volatile device atomic_uint *)p, v, memory_order_relaxed); }
static inline int atomic_inc(volatile device int *p) { return atomic_add(p, 1); }
static inline uint atomic_inc(volatile device uint *p) { return atomic_add(p, 1u); }
static inline int atomic_max(volatile device int *p, int v) { return atomic_fetch_max_explicit((volatile device atomic_int *)p, v, memory_order_relaxed); }
static inline int atomic_min(volatile device int *p, int v) { return atomic_fetch_min_explicit((volatile device atomic_int *)p, v, memory_order_relaxed); }
static inline int atomic_xchg(volatile device int *p, int v) { return atomic_exchange_explicit((volatile device atomic_int *)p, v, memory_order_relaxed); }
static inline int atomic_cmpxchg(volatile device int *p, int cmp, int v)
{
  atomic_compare_exchange_weak_explicit((volatile device atomic_int *)p, &cmp, v, memory_order_relaxed, memory_order_relaxed);
  return cmp;   // the old value, as OpenCL returns
}
static inline uint atomic_cmpxchg(volatile device uint *p, uint cmp, uint v)
{
  atomic_compare_exchange_weak_explicit((volatile device atomic_uint *)p, &cmp, v, memory_order_relaxed, memory_order_relaxed);
  return cmp;
}
