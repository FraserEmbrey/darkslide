/*
  MetalCL: the 40 OpenCL 1.2 entry points darktable loads at runtime
  (src/common/dlopencl.c), implemented on Metal.

  darktable selects it with the conf key opencl_library, so its GPU path
  runs on Metal with no change to darktable's source. Kernels are not
  compiled from OpenCL C: the source string darktable passes is matched
  against the .cl files in the -I<kerneldir> of the build options, and the
  translation Engine/metal/cl2metal.py made of that file (<name>.metal plus
  the <name>.json argument map) is compiled instead.

  Where the translations are looked for, in order:
    $DT_METALCL_KERNELS
    <kerneldir>/../metal-kernels   (Engine/metalcl/build.sh installs them there)

  Other environment variables:
    DT_METALCL_MATH=fast|relaxed|safe  overrides the maths mode (by default
                                       fast when darktable asks for
                                       -cl-fast-relaxed-math, else relaxed)
    DT_METALCL_BATCH=N                 commands per command buffer at most (default 4)
    DT_METALCL_DEBUG=1                 logs program builds and errors to stderr

  Objects are Objective-C objects behind the opaque cl_* pointers, with an
  OpenCL reference count on top of ARC. One process-wide lock guards all
  shared state; waits for the GPU happen outside it.

  The queue is in order. Commands are encoded into one open command buffer
  (one compute encoder for consecutive kernels, one blit encoder for
  consecutive copies), which is committed as soon as the GPU has finished
  the previous one, after N commands at most, and whenever the host has to
  wait: blocking reads, maps, clFinish, clWaitForEvents. With
  CL_QUEUE_PROFILING_ENABLE every command gets its own command buffer, so
  event timings are per command.
*/

#define CL_SILENCE_DEPRECATION
#define CL_TARGET_OPENCL_VERSION 120
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <OpenCL/cl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#define MCL_VERSION "MetalCL 1.0"

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
#define LOCK() pthread_mutex_lock(&g_lock)
#define UNLOCK() pthread_mutex_unlock(&g_lock)

static int g_debug = -1;
static void dbg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void dbg(const char *fmt, ...)
{
  if(g_debug < 0) g_debug = getenv("DT_METALCL_DEBUG") ? atoi(getenv("DT_METALCL_DEBUG")) : 0;
  if(!g_debug) return;
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "[metalcl] ");
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  va_end(ap);
}

// errors are always worth seeing, debug or not
static void err_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void err_log(const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "[metalcl] ERROR: ");
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  va_end(ap);
}

// ------------------------------------------------------------------ objects

@interface MCLObject : NSObject
{
@public
  int refs;
}
@end
@implementation MCLObject
@end

@interface MCLPlatform : MCLObject
@end
@implementation MCLPlatform
@end

@interface MCLDevice : MCLObject
{
@public
  id<MTLDevice> mtl;
  id<MTLBuffer> dummyBuffer;
  id<MTLTexture> dummyFloat, dummyUInt;
}
@end
@implementation MCLDevice
@end

@interface MCLContext : MCLObject
{
@public
  MCLDevice *device;
}
@end
@implementation MCLContext
@end

@interface MCLQueue : MCLObject
{
@public
  MCLContext *context;
  id<MTLCommandQueue> queue;
  id<MTLCommandBuffer> cur;          // open, not yet committed
  id<MTLComputeCommandEncoder> compute;
  id<MTLBlitCommandEncoder> blit;
  id<MTLCommandBuffer> last;         // last committed
  int pending;                       // commands in cur
  BOOL profiling;
  cl_command_queue_properties props;
}
@end
@implementation MCLQueue
@end

@interface MCLMem : MCLObject
{
@public
  MCLContext *context;
  cl_mem_flags flags;
  cl_mem_object_type type;
  size_t size;
  void *hostPtr;
  id<MTLBuffer> buffer;
  id<MTLTexture> texture;
  cl_image_format format;
  size_t width, height, elsize;
  int mapCount;
}
@end
@implementation MCLMem
@end

// one OpenCL argument of a kernel, from the .json argument map
typedef enum { ARG_TEXTURE, ARG_BUFFER, ARG_LOCAL, ARG_SCALAR } arg_kind_t;
typedef struct
{
  arg_kind_t kind;
  int slot;          // texture, buffer or threadgroup index; struct field for scalars
  BOOL write;        // texture written by the kernel
  size_t offset;     // scalars: offset in the argument struct
  size_t span;       // scalars: bytes up to the next member
  size_t expect;     // scalars: exact OpenCL size if known, else 0
  BOOL uintTexture;  // textures: texture2d<uint>
} arg_info_t;

@interface MCLProgram : MCLObject
{
@public
  MCLContext *context;
  NSString *name;                      // kernel file without .cl, e.g. "basic"
  NSData *source;
  NSString *options;
  NSString *log;
  cl_build_status status;
  NSDictionary *argmap;                // kernel name -> array of arg dictionaries
  id<MTLLibrary> library;
  dispatch_group_t compiling;
  NSError *compileError;
  NSMutableDictionary *pipelines;      // kernel name -> NSValue-wrapped info, see MCLKernelInfo
  int kernels;                         // live kernel objects, for CL_PROGRAM_NUM_KERNELS
}
@end
@implementation MCLProgram
@end

// compiled state shared by all kernel objects of the same name
@interface MCLKernelInfo : NSObject
{
@public
  id<MTLComputePipelineState> pipeline;
  int nargs;
  arg_info_t *args;
  size_t structSize;
}
@end
@implementation MCLKernelInfo
- (void)dealloc
{
  free(args);
}
@end

@interface MCLKernel : MCLObject
{
@public
  MCLProgram *program;
  NSString *name;
  MCLKernelInfo *info;
  // per arg: the bound memory object, not retained (OpenCL kernels don't
  // retain their arguments, and holding them would keep large images alive)
  void **mems;
  size_t *localSizes;
  uint8_t *argStruct;
  BOOL *isSet;
}
@end
@implementation MCLKernel
- (void)dealloc
{
  free(mems);
  free(localSizes);
  free(argStruct);
  free(isSet);
}
@end

@interface MCLEvent : MCLObject
{
@public
  MCLQueue *queue;
  MCLContext *context;
  id<MTLCommandBuffer> cb;   // nil when the command completed on the host
  cl_command_type type;
}
@end
@implementation MCLEvent
@end

// opaque pointer <-> object. Every handle given out is kept in a registry,
// so a stale or garbage handle is rejected with an error instead of crashing
#define AS(T, p) ((__bridge T *)(void *)(p))
static pthread_mutex_t g_reg_lock = PTHREAD_MUTEX_INITIALIZER;
static CFMutableSetRef g_live;
static void reg_add(const void *p)
{
  pthread_mutex_lock(&g_reg_lock);
  if(!g_live) g_live = CFSetCreateMutable(NULL, 0, NULL);
  CFSetAddValue(g_live, p);
  pthread_mutex_unlock(&g_reg_lock);
}
static BOOL reg_has(const void *p)
{
  pthread_mutex_lock(&g_reg_lock);
  const BOOL has = g_live && CFSetContainsValue(g_live, p);
  pthread_mutex_unlock(&g_reg_lock);
  return has;
}
static void *retain_out(MCLObject *o)
{
  o->refs = 1;
  void *p = (__bridge_retained void *)o;
  reg_add(p);
  return p;
}
static BOOL is_a(const void *p, Class cls)
{
  return p && reg_has(p) && [(__bridge id)(void *)p isKindOfClass:cls];
}
static cl_int release_obj(void *p, Class cls, cl_int invalid)
{
  if(!is_a(p, cls)) return invalid;
  MCLObject *o = (__bridge MCLObject *)p;
  LOCK();
  const int left = --o->refs;
  UNLOCK();
  if(left == 0)
  {
    pthread_mutex_lock(&g_reg_lock);
    CFSetRemoveValue(g_live, p);
    pthread_mutex_unlock(&g_reg_lock);
    CFBridgingRelease(p);
  }
  return CL_SUCCESS;
}

// ------------------------------------------------------------ the singletons

static MCLPlatform *g_platform;
static MCLDevice *g_device;
static void *g_platform_id, *g_device_id;

static void init_once(void)
{
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    @autoreleasepool
    {
      id<MTLDevice> mtl = MTLCreateSystemDefaultDevice();
      if(!mtl) return;
      g_platform = [MCLPlatform new];
      g_platform->refs = 1;
      g_platform_id = (__bridge_retained void *)g_platform;
      reg_add(g_platform_id);
      g_device = [MCLDevice new];
      g_device->refs = 1;
      g_device->mtl = mtl;
      // bound in place of NULL arguments, which OpenCL allows and Metal doesn't
      g_device->dummyBuffer = [mtl newBufferWithLength:256 options:MTLResourceStorageModeShared];
      MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                                   width:1 height:1 mipmapped:NO];
      d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
      d.storageMode = MTLStorageModePrivate;
      g_device->dummyFloat = [mtl newTextureWithDescriptor:d];
      d.pixelFormat = MTLPixelFormatRGBA32Uint;
      g_device->dummyUInt = [mtl newTextureWithDescriptor:d];
      g_device_id = (__bridge_retained void *)g_device;
      reg_add(g_device_id);
    }
  });
}

static cl_int ret_info(const void *src, size_t n, size_t size, void *dst, size_t *ret)
{
  if(dst)
  {
    if(size < n) return CL_INVALID_VALUE;
    memcpy(dst, src, n);
  }
  if(ret) *ret = n;
  return CL_SUCCESS;
}
static cl_int ret_str(const char *s, size_t size, void *dst, size_t *ret)
{
  return ret_info(s, strlen(s) + 1, size, dst, ret);
}
#define RET(T, v) do { const T _v = (v); return ret_info(&_v, sizeof(T), param_value_size, param_value, param_value_size_ret); } while(0)
#define RETS(s) return ret_str((s), param_value_size, param_value, param_value_size_ret)

// --------------------------------------------------------- platform, device

cl_int clGetPlatformIDs(cl_uint num_entries, cl_platform_id *platforms, cl_uint *num_platforms)
{
  if((num_entries == 0 && platforms) || (!platforms && !num_platforms)) return CL_INVALID_VALUE;
  init_once();
  if(!g_platform)
  {
    if(num_platforms) *num_platforms = 0;
    return -1001 /* CL_PLATFORM_NOT_FOUND_KHR */;
  }
  if(platforms) platforms[0] = (cl_platform_id)g_platform_id;
  if(num_platforms) *num_platforms = 1;
  return CL_SUCCESS;
}

cl_int clGetPlatformInfo(cl_platform_id platform, cl_platform_info param_name, size_t param_value_size,
                         void *param_value, size_t *param_value_size_ret)
{
  init_once();
  if(platform && platform != (cl_platform_id)g_platform_id) return CL_INVALID_PLATFORM;
  switch(param_name)
  {
    case CL_PLATFORM_PROFILE: RETS("FULL_PROFILE");
    case CL_PLATFORM_VERSION: RETS("OpenCL 1.2 " MCL_VERSION);
    // "Apple" keeps darktable's clplatform_apple switch, on by default on macOS
    case CL_PLATFORM_NAME: RETS("Apple");
    case CL_PLATFORM_VENDOR: RETS("Apple");
    case CL_PLATFORM_EXTENSIONS: RETS("");
    default: return CL_INVALID_VALUE;
  }
}

cl_int clGetDeviceIDs(cl_platform_id platform, cl_device_type device_type, cl_uint num_entries,
                      cl_device_id *devices, cl_uint *num_devices)
{
  init_once();
  if(platform && platform != (cl_platform_id)g_platform_id) return CL_INVALID_PLATFORM;
  if(!g_device) return CL_DEVICE_NOT_FOUND;
  if((num_entries == 0 && devices) || (!devices && !num_devices)) return CL_INVALID_VALUE;
  if(!(device_type & (CL_DEVICE_TYPE_GPU | CL_DEVICE_TYPE_DEFAULT)) && device_type != CL_DEVICE_TYPE_ALL)
  {
    if(num_devices) *num_devices = 0;
    return CL_DEVICE_NOT_FOUND;
  }
  if(devices) devices[0] = (cl_device_id)g_device_id;
  if(num_devices) *num_devices = 1;
  return CL_SUCCESS;
}

static cl_ulong global_mem(void)
{
  return g_device->mtl.recommendedMaxWorkingSetSize;
}
static cl_ulong max_alloc(void)
{
  return MIN((cl_ulong)g_device->mtl.maxBufferLength, global_mem());
}
static size_t max_wg(void)
{
  return g_device->mtl.maxThreadsPerThreadgroup.width;
}

static cl_int clGetDeviceInfo_impl(cl_device_id device, cl_device_info param_name, size_t param_value_size,
                       void *param_value, size_t *param_value_size_ret)
{
  init_once();
  if(!g_device || device != (cl_device_id)g_device_id) return CL_INVALID_DEVICE;
  id<MTLDevice> mtl = g_device->mtl;
  switch(param_name)
  {
    case CL_DEVICE_TYPE: RET(cl_device_type, CL_DEVICE_TYPE_GPU);
    case CL_DEVICE_VENDOR_ID: RET(cl_uint, 0x1027f00); // Apple, as darktable's DT_OPENCL_VENDOR_APPLE
    case CL_DEVICE_MAX_COMPUTE_UNITS:
    {
      // Metal doesn't say; the GPU core count is in the IORegistry, the
      // threadgroup memory per core is a fair stand-in
      cl_uint cu = 8;
      NSString *n = mtl.name;
      if([n containsString:@"Max"]) cu = 32;
      else if([n containsString:@"Pro"]) cu = 16;
      else if([n containsString:@"Ultra"]) cu = 64;
      RET(cl_uint, cu);
    }
    case CL_DEVICE_MAX_WORK_ITEM_DIMENSIONS: RET(cl_uint, 3);
    case CL_DEVICE_MAX_WORK_ITEM_SIZES:
    {
      const MTLSize m = mtl.maxThreadsPerThreadgroup;
      const size_t s[3] = { m.width, m.height, m.depth };
      return ret_info(s, sizeof(s), param_value_size, param_value, param_value_size_ret);
    }
    case CL_DEVICE_MAX_WORK_GROUP_SIZE: RET(size_t, max_wg());
    case CL_DEVICE_PREFERRED_VECTOR_WIDTH_CHAR:
    case CL_DEVICE_PREFERRED_VECTOR_WIDTH_SHORT:
    case CL_DEVICE_PREFERRED_VECTOR_WIDTH_INT:
    case CL_DEVICE_PREFERRED_VECTOR_WIDTH_LONG:
    case CL_DEVICE_PREFERRED_VECTOR_WIDTH_FLOAT:
    case CL_DEVICE_NATIVE_VECTOR_WIDTH_CHAR:
    case CL_DEVICE_NATIVE_VECTOR_WIDTH_SHORT:
    case CL_DEVICE_NATIVE_VECTOR_WIDTH_INT:
    case CL_DEVICE_NATIVE_VECTOR_WIDTH_LONG:
    case CL_DEVICE_NATIVE_VECTOR_WIDTH_FLOAT: RET(cl_uint, 1);
    case CL_DEVICE_PREFERRED_VECTOR_WIDTH_DOUBLE:
    case CL_DEVICE_PREFERRED_VECTOR_WIDTH_HALF:
    case CL_DEVICE_NATIVE_VECTOR_WIDTH_DOUBLE:
    case CL_DEVICE_NATIVE_VECTOR_WIDTH_HALF: RET(cl_uint, 0);
    case CL_DEVICE_MAX_CLOCK_FREQUENCY: RET(cl_uint, 1000);
    case CL_DEVICE_ADDRESS_BITS: RET(cl_uint, 64);
    case CL_DEVICE_MAX_READ_IMAGE_ARGS: RET(cl_uint, 128);
    case CL_DEVICE_MAX_WRITE_IMAGE_ARGS: RET(cl_uint, 8);
    case CL_DEVICE_MAX_MEM_ALLOC_SIZE: RET(cl_ulong, max_alloc());
    case CL_DEVICE_IMAGE2D_MAX_WIDTH:
    case CL_DEVICE_IMAGE2D_MAX_HEIGHT: RET(size_t, 16384);
    case CL_DEVICE_IMAGE3D_MAX_WIDTH:
    case CL_DEVICE_IMAGE3D_MAX_HEIGHT:
    case CL_DEVICE_IMAGE3D_MAX_DEPTH: RET(size_t, 2048);
    case CL_DEVICE_IMAGE_MAX_BUFFER_SIZE: RET(size_t, 1 << 26);
    case CL_DEVICE_IMAGE_MAX_ARRAY_SIZE: RET(size_t, 2048);
    case CL_DEVICE_IMAGE_SUPPORT: RET(cl_bool, CL_TRUE);
    case CL_DEVICE_MAX_PARAMETER_SIZE: RET(size_t, 4096);
    case CL_DEVICE_MAX_SAMPLERS: RET(cl_uint, 16);
    case CL_DEVICE_MEM_BASE_ADDR_ALIGN: RET(cl_uint, 4096 * 8);
    case CL_DEVICE_MIN_DATA_TYPE_ALIGN_SIZE: RET(cl_uint, 128);
    case CL_DEVICE_SINGLE_FP_CONFIG:
      RET(cl_device_fp_config, CL_FP_INF_NAN | CL_FP_ROUND_TO_NEAREST);
    case CL_DEVICE_DOUBLE_FP_CONFIG: RET(cl_device_fp_config, 0);
    case CL_DEVICE_GLOBAL_MEM_CACHE_TYPE: RET(cl_device_mem_cache_type, CL_READ_WRITE_CACHE);
    case CL_DEVICE_GLOBAL_MEM_CACHELINE_SIZE: RET(cl_uint, 128);
    case CL_DEVICE_GLOBAL_MEM_CACHE_SIZE: RET(cl_ulong, 8 << 20);
    case CL_DEVICE_GLOBAL_MEM_SIZE: RET(cl_ulong, global_mem());
    case CL_DEVICE_MAX_CONSTANT_BUFFER_SIZE: RET(cl_ulong, 64 << 10);
    case CL_DEVICE_MAX_CONSTANT_ARGS: RET(cl_uint, 8);
    case CL_DEVICE_LOCAL_MEM_TYPE: RET(cl_device_local_mem_type, CL_LOCAL);
    case CL_DEVICE_LOCAL_MEM_SIZE: RET(cl_ulong, MIN((cl_ulong)mtl.maxThreadgroupMemoryLength, 32 << 10));
    case CL_DEVICE_ERROR_CORRECTION_SUPPORT: RET(cl_bool, CL_FALSE);
    case CL_DEVICE_HOST_UNIFIED_MEMORY: RET(cl_bool, mtl.hasUnifiedMemory ? CL_TRUE : CL_FALSE);
    case CL_DEVICE_PROFILING_TIMER_RESOLUTION: RET(size_t, 1000);
    case CL_DEVICE_ENDIAN_LITTLE: RET(cl_bool, CL_TRUE);
    case CL_DEVICE_AVAILABLE: RET(cl_bool, CL_TRUE);
    case CL_DEVICE_COMPILER_AVAILABLE: RET(cl_bool, CL_TRUE);
    case CL_DEVICE_LINKER_AVAILABLE: RET(cl_bool, CL_FALSE);
    case CL_DEVICE_EXECUTION_CAPABILITIES: RET(cl_device_exec_capabilities, CL_EXEC_KERNEL);
    case CL_DEVICE_QUEUE_PROPERTIES: RET(cl_command_queue_properties, CL_QUEUE_PROFILING_ENABLE);
    case CL_DEVICE_PLATFORM: RET(cl_platform_id, (cl_platform_id)g_platform_id);
    case CL_DEVICE_NAME:
      RETS([[mtl.name stringByAppendingString:@" (Metal)"] UTF8String]);
    case CL_DEVICE_VENDOR: RETS("Apple");
    case CL_DRIVER_VERSION: RETS(MCL_VERSION);
    case CL_DEVICE_PROFILE: RETS("FULL_PROFILE");
    case CL_DEVICE_VERSION: RETS("OpenCL 1.2 " MCL_VERSION);
    case CL_DEVICE_OPENCL_C_VERSION: RETS("OpenCL C 1.2 ");
    case CL_DEVICE_EXTENSIONS:
      RETS("cl_khr_global_int32_base_atomics cl_khr_global_int32_extended_atomics "
           "cl_khr_local_int32_base_atomics cl_khr_local_int32_extended_atomics "
           "cl_khr_byte_addressable_store");
    case CL_DEVICE_BUILT_IN_KERNELS: RETS("");
    case CL_DEVICE_PRINTF_BUFFER_SIZE: RET(size_t, 0);
    case CL_DEVICE_PREFERRED_INTEROP_USER_SYNC: RET(cl_bool, CL_TRUE);
    case CL_DEVICE_PARENT_DEVICE: RET(cl_device_id, NULL);
    case CL_DEVICE_PARTITION_MAX_SUB_DEVICES: RET(cl_uint, 0);
    case CL_DEVICE_REFERENCE_COUNT: RET(cl_uint, 1);
    default:
      dbg("clGetDeviceInfo: unknown param 0x%x", param_name);
      return CL_INVALID_VALUE;
  }
}

// autorelease pool: darktable's threads have none
cl_int clGetDeviceInfo(cl_device_id device, cl_device_info param_name, size_t param_value_size,
                       void *param_value, size_t *param_value_size_ret)
{
  @autoreleasepool
  {
    return clGetDeviceInfo_impl(device, param_name, param_value_size, param_value, param_value_size_ret);
  }
}

// ------------------------------------------------------------ context, queue

cl_context clCreateContext(const cl_context_properties *properties, cl_uint num_devices,
                           const cl_device_id *devices,
                           void (*pfn_notify)(const char *, const void *, size_t, void *),
                           void *user_data, cl_int *errcode_ret)
{
  init_once();
  cl_int err = CL_SUCCESS;
  if(!devices || num_devices == 0) err = CL_INVALID_VALUE;
  else
    for(cl_uint i = 0; i < num_devices; i++)
      if(devices[i] != (cl_device_id)g_device_id) err = CL_INVALID_DEVICE;
  if(errcode_ret) *errcode_ret = err;
  if(err != CL_SUCCESS) return NULL;
  MCLContext *c = [MCLContext new];
  c->device = g_device;
  return (cl_context)retain_out(c);
}

cl_int clReleaseContext(cl_context context)
{
  return release_obj(context, [MCLContext class], CL_INVALID_CONTEXT);
}

cl_command_queue clCreateCommandQueue(cl_context context, cl_device_id device,
                                      cl_command_queue_properties properties, cl_int *errcode_ret)
{
  cl_int err = CL_SUCCESS;
  if(!is_a(context, [MCLContext class])) err = CL_INVALID_CONTEXT;
  else if(device != (cl_device_id)g_device_id) err = CL_INVALID_DEVICE;
  else if(properties & ~(cl_command_queue_properties)(CL_QUEUE_PROFILING_ENABLE | CL_QUEUE_OUT_OF_ORDER_EXEC_MODE_ENABLE))
    err = CL_INVALID_VALUE;
  if(errcode_ret) *errcode_ret = err;
  if(err != CL_SUCCESS) return NULL;
  MCLQueue *q = [MCLQueue new];
  q->context = AS(MCLContext, context);
  q->queue = [g_device->mtl newCommandQueueWithMaxCommandBufferCount:256];
  q->profiling = (properties & CL_QUEUE_PROFILING_ENABLE) != 0;
  q->props = properties;
  if(!q->queue)
  {
    if(errcode_ret) *errcode_ret = CL_OUT_OF_RESOURCES;
    return NULL;
  }
  q->queue.label = @"MetalCL";
  return (cl_command_queue)retain_out(q);
}

static int batch_size(void)
{
  static int n = 0;
  if(!n)
  {
    const char *e = getenv("DT_METALCL_BATCH");
    n = e && atoi(e) > 0 ? atoi(e) : 4;
  }
  return n;
}

// all q_* helpers run with the lock held
static id<MTLCommandBuffer> q_cb(MCLQueue *q)
{
  if(!q->cur)
  {
    q->cur = [q->queue commandBuffer];
    q->pending = 0;
  }
  return q->cur;
}

static void q_end_encoders(MCLQueue *q)
{
  if(q->compute)
  {
    [q->compute endEncoding];
    q->compute = nil;
  }
  if(q->blit)
  {
    [q->blit endEncoding];
    q->blit = nil;
  }
}

static id<MTLComputeCommandEncoder> q_compute(MCLQueue *q)
{
  if(q->blit)
  {
    [q->blit endEncoding];
    q->blit = nil;
  }
  // serial dispatch: each kernel sees everything the previous one wrote
  if(!q->compute) q->compute = [q_cb(q) computeCommandEncoderWithDispatchType:MTLDispatchTypeSerial];
  return q->compute;
}

static id<MTLBlitCommandEncoder> q_blit(MCLQueue *q)
{
  if(q->compute)
  {
    [q->compute endEncoding];
    q->compute = nil;
  }
  if(!q->blit) q->blit = [q_cb(q) blitCommandEncoder];
  return q->blit;
}

static void report_error(id<MTLCommandBuffer> cb)
{
  if(cb.status == MTLCommandBufferStatusError)
    err_log("command buffer failed: %s", cb.error.localizedDescription.UTF8String ?: "unknown error");
}

// commits the open command buffer; returns the one to wait on for everything so far
static id<MTLCommandBuffer> q_flush(MCLQueue *q)
{
  if(q->cur)
  {
    q_end_encoders(q);
    [q->cur addCompletedHandler:^(id<MTLCommandBuffer> cb) { report_error(cb); }];
    [q->cur commit];
    q->last = q->cur;
    q->cur = nil;
    q->pending = 0;
  }
  return q->last;
}

// counts a command; commits when the batch is full, or always when profiling
static BOOL gpu_done(id<MTLCommandBuffer> cb)
{
  if(!cb) return YES;
  const MTLCommandBufferStatus s = cb.status;
  return s == MTLCommandBufferStatusCompleted || s == MTLCommandBufferStatusError;
}

static BOOL q_idle(MCLQueue *q)
{
  return !q->cur && gpu_done(q->last);
}

// counts a command and decides whether to commit: at once when the GPU has
// run dry, so it never waits for the batch to fill, else when the batch is
// full; always when profiling, for per-command timings
static void q_after_command(MCLQueue *q)
{
  q->pending++;
  if(q->profiling || q->pending >= batch_size() || gpu_done(q->last)) q_flush(q);
}

// flushes and waits for everything enqueued so far; call without the lock
static cl_int q_finish(MCLQueue *q)
{
  LOCK();
  id<MTLCommandBuffer> cb = q_flush(q);
  UNLOCK();
  if(!cb) return CL_SUCCESS;
  [cb waitUntilCompleted];
  return cb.status == MTLCommandBufferStatusError ? CL_OUT_OF_RESOURCES : CL_SUCCESS;
}

static void make_event(MCLQueue *q, cl_command_type type, id<MTLCommandBuffer> cb, cl_event *event)
{
  if(!event) return;
  MCLEvent *e = [MCLEvent new];
  e->queue = q;
  e->context = q->context;
  e->cb = cb;
  e->type = type;
  *event = (cl_event)retain_out(e);
}

// waits on an event list before a command; the queue is in order, so only
// events from other queues matter, and waiting on them is enough
static cl_int wait_list(cl_uint n, const cl_event *list)
{
  if((n == 0) != (list == NULL)) return CL_INVALID_EVENT_WAIT_LIST;
  if(n == 0) return CL_SUCCESS;
  return clWaitForEvents(n, list);
}

cl_int clFinish(cl_command_queue command_queue)
{
  if(!is_a(command_queue, [MCLQueue class])) return CL_INVALID_COMMAND_QUEUE;
  @autoreleasepool
  {
    return q_finish(AS(MCLQueue, command_queue));
  }
}

cl_int clReleaseCommandQueue(cl_command_queue command_queue)
{
  if(!is_a(command_queue, [MCLQueue class])) return CL_INVALID_COMMAND_QUEUE;
  MCLQueue *q = AS(MCLQueue, command_queue);
  BOOL last;
  LOCK();
  last = q->refs == 1;
  UNLOCK();
  if(last) clFinish(command_queue);
  return release_obj(command_queue, [MCLQueue class], CL_INVALID_COMMAND_QUEUE);
}

// ------------------------------------------------------------------- events

cl_int clWaitForEvents(cl_uint num_events, const cl_event *event_list)
{
  if(num_events == 0 || !event_list) return CL_INVALID_VALUE;
  cl_int res = CL_SUCCESS;
  @autoreleasepool
  {
    for(cl_uint i = 0; i < num_events; i++)
    {
      if(!is_a(event_list[i], [MCLEvent class])) return CL_INVALID_EVENT;
      MCLEvent *e = AS(MCLEvent, event_list[i]);
      LOCK();
      id<MTLCommandBuffer> cb = e->cb;
      if(cb && cb == e->queue->cur) q_flush(e->queue);
      UNLOCK();
      if(!cb) continue;
      [cb waitUntilCompleted];
      if(cb.status == MTLCommandBufferStatusError) res = CL_EXEC_STATUS_ERROR_FOR_EVENTS_IN_WAIT_LIST;
    }
  }
  return res;
}

cl_int clGetEventInfo(cl_event event, cl_event_info param_name, size_t param_value_size, void *param_value,
                      size_t *param_value_size_ret)
{
  if(!is_a(event, [MCLEvent class])) return CL_INVALID_EVENT;
  MCLEvent *e = AS(MCLEvent, event);
  switch(param_name)
  {
    case CL_EVENT_COMMAND_QUEUE: RET(cl_command_queue, (__bridge cl_command_queue)e->queue);
    case CL_EVENT_CONTEXT: RET(cl_context, (__bridge cl_context)e->context);
    case CL_EVENT_COMMAND_TYPE: RET(cl_command_type, e->type);
    case CL_EVENT_REFERENCE_COUNT: RET(cl_uint, (cl_uint)e->refs);
    case CL_EVENT_COMMAND_EXECUTION_STATUS:
    {
      cl_int s = CL_COMPLETE;
      if(e->cb)
        switch(e->cb.status)
        {
          case MTLCommandBufferStatusNotEnqueued:
          case MTLCommandBufferStatusEnqueued: s = CL_QUEUED; break;
          case MTLCommandBufferStatusCommitted: s = CL_SUBMITTED; break;
          case MTLCommandBufferStatusScheduled: s = CL_RUNNING; break;
          case MTLCommandBufferStatusCompleted: s = CL_COMPLETE; break;
          case MTLCommandBufferStatusError: s = CL_OUT_OF_RESOURCES; break;
        }
      RET(cl_int, s);
    }
    default: return CL_INVALID_VALUE;
  }
}

cl_int clGetEventProfilingInfo(cl_event event, cl_profiling_info param_name, size_t param_value_size,
                               void *param_value, size_t *param_value_size_ret)
{
  if(!is_a(event, [MCLEvent class])) return CL_INVALID_EVENT;
  MCLEvent *e = AS(MCLEvent, event);
  if(e->cb && e->cb.status != MTLCommandBufferStatusCompleted) return CL_PROFILING_INFO_NOT_AVAILABLE;
  // GPU times of the command buffer; host-side commands report zero
  const double start = e->cb ? e->cb.GPUStartTime : 0.0, end = e->cb ? e->cb.GPUEndTime : 0.0;
  switch(param_name)
  {
    case CL_PROFILING_COMMAND_QUEUED:
    case CL_PROFILING_COMMAND_SUBMIT:
    case CL_PROFILING_COMMAND_START: RET(cl_ulong, (cl_ulong)(start * 1e9));
    case CL_PROFILING_COMMAND_END: RET(cl_ulong, (cl_ulong)(end * 1e9));
    default: return CL_INVALID_VALUE;
  }
}

cl_int clReleaseEvent(cl_event event)
{
  return release_obj(event, [MCLEvent class], CL_INVALID_EVENT);
}

// ------------------------------------------------------------------- memory

static MTLPixelFormat pixel_format(const cl_image_format *f, size_t *elsize)
{
  int ch;
  switch(f->image_channel_order)
  {
    case CL_R: ch = 1; break;
    case CL_RG: ch = 2; break;
    case CL_RGBA: ch = 4; break;
    default: return MTLPixelFormatInvalid;
  }
  static const MTLPixelFormat fl[] = { MTLPixelFormatR32Float, MTLPixelFormatRG32Float, 0, MTLPixelFormatRGBA32Float };
  static const MTLPixelFormat hf[] = { MTLPixelFormatR16Float, MTLPixelFormatRG16Float, 0, MTLPixelFormatRGBA16Float };
  static const MTLPixelFormat u8[] = { MTLPixelFormatR8Uint, MTLPixelFormatRG8Uint, 0, MTLPixelFormatRGBA8Uint };
  static const MTLPixelFormat u16[] = { MTLPixelFormatR16Uint, MTLPixelFormatRG16Uint, 0, MTLPixelFormatRGBA16Uint };
  static const MTLPixelFormat u32[] = { MTLPixelFormatR32Uint, MTLPixelFormatRG32Uint, 0, MTLPixelFormatRGBA32Uint };
  static const MTLPixelFormat n8[] = { MTLPixelFormatR8Unorm, MTLPixelFormatRG8Unorm, 0, MTLPixelFormatRGBA8Unorm };
  static const MTLPixelFormat n16[] = { MTLPixelFormatR16Unorm, MTLPixelFormatRG16Unorm, 0, MTLPixelFormatRGBA16Unorm };
  switch(f->image_channel_data_type)
  {
    case CL_FLOAT: *elsize = 4 * ch; return fl[ch - 1];
    case CL_HALF_FLOAT: *elsize = 2 * ch; return hf[ch - 1];
    case CL_UNSIGNED_INT8: *elsize = ch; return u8[ch - 1];
    case CL_UNSIGNED_INT16: *elsize = 2 * ch; return u16[ch - 1];
    case CL_UNSIGNED_INT32: *elsize = 4 * ch; return u32[ch - 1];
    case CL_UNORM_INT8: *elsize = ch; return n8[ch - 1];
    case CL_UNORM_INT16: *elsize = 2 * ch; return n16[ch - 1];
    default: return MTLPixelFormatInvalid;
  }
}

cl_mem clCreateBuffer(cl_context context, cl_mem_flags flags, size_t size, void *host_ptr, cl_int *errcode_ret)
{
  cl_int err = CL_SUCCESS;
  const BOOL wantsHost = (flags & (CL_MEM_COPY_HOST_PTR | CL_MEM_USE_HOST_PTR)) != 0;
  if(!is_a(context, [MCLContext class])) err = CL_INVALID_CONTEXT;
  else if(size == 0 || size > max_alloc()) err = CL_INVALID_BUFFER_SIZE;
  else if(wantsHost != (host_ptr != NULL)) err = CL_INVALID_HOST_PTR;
  if(err != CL_SUCCESS)
  {
    if(errcode_ret) *errcode_ret = err;
    return NULL;
  }
  @autoreleasepool
  {
    id<MTLDevice> mtl = g_device->mtl;
    id<MTLBuffer> b = wantsHost ? [mtl newBufferWithBytes:host_ptr length:size options:MTLResourceStorageModeShared]
                                : [mtl newBufferWithLength:size options:MTLResourceStorageModeShared];
    if(!b)
    {
      if(errcode_ret) *errcode_ret = CL_MEM_OBJECT_ALLOCATION_FAILURE;
      return NULL;
    }
    MCLMem *m = [MCLMem new];
    m->context = AS(MCLContext, context);
    m->flags = flags;
    m->type = CL_MEM_OBJECT_BUFFER;
    m->size = size;
    m->hostPtr = (flags & CL_MEM_USE_HOST_PTR) ? host_ptr : NULL;
    m->buffer = b;
    if(errcode_ret) *errcode_ret = CL_SUCCESS;
    return (cl_mem)retain_out(m);
  }
}

// copies rows from host memory to a texture region through a staging buffer,
// encoded in order on the queue (lock held)
static void blit_host_to_texture(MCLQueue *q, MCLMem *m, const size_t *origin, const size_t *region,
                                 size_t row_pitch, const void *host)
{
  const size_t rowbytes = region[0] * m->elsize;
  if(row_pitch == 0) row_pitch = rowbytes;
  const size_t bytes = row_pitch * (region[1] - 1) + rowbytes;
  id<MTLBuffer> staging = [g_device->mtl newBufferWithBytes:host length:bytes options:MTLResourceStorageModeShared];
  [q_blit(q) copyFromBuffer:staging
               sourceOffset:0
          sourceBytesPerRow:row_pitch
        sourceBytesPerImage:row_pitch * region[1]
                 sourceSize:MTLSizeMake(region[0], region[1], 1)
                  toTexture:m->texture
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(origin[0], origin[1], 0)];
}

cl_mem clCreateImage(cl_context context, cl_mem_flags flags, const cl_image_format *image_format,
                     const cl_image_desc *image_desc, void *host_ptr, cl_int *errcode_ret)
{
  cl_int err = CL_SUCCESS;
  size_t elsize = 0;
  MTLPixelFormat pf = MTLPixelFormatInvalid;
  const BOOL wantsHost = (flags & (CL_MEM_COPY_HOST_PTR | CL_MEM_USE_HOST_PTR)) != 0;
  if(!is_a(context, [MCLContext class])) err = CL_INVALID_CONTEXT;
  else if(!image_format) err = CL_INVALID_IMAGE_FORMAT_DESCRIPTOR;
  else if(!image_desc || image_desc->image_type != CL_MEM_OBJECT_IMAGE2D) err = CL_INVALID_IMAGE_DESCRIPTOR;
  else if((pf = pixel_format(image_format, &elsize)) == MTLPixelFormatInvalid) err = CL_IMAGE_FORMAT_NOT_SUPPORTED;
  else if(image_desc->image_width == 0 || image_desc->image_height == 0 || image_desc->image_width > 16384
          || image_desc->image_height > 16384)
    err = CL_INVALID_IMAGE_SIZE;
  else if(wantsHost != (host_ptr != NULL)) err = CL_INVALID_HOST_PTR;
  if(err != CL_SUCCESS)
  {
    if(errcode_ret) *errcode_ret = err;
    if(err == CL_IMAGE_FORMAT_NOT_SUPPORTED)
      err_log("image format order 0x%x type 0x%x not supported", image_format->image_channel_order,
              image_format->image_channel_data_type);
    return NULL;
  }
  @autoreleasepool
  {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf
                                                                                 width:image_desc->image_width
                                                                                height:image_desc->image_height
                                                                             mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    // private storage lets the GPU keep textures compressed; host transfers
    // go through staging buffers anyway
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [g_device->mtl newTextureWithDescriptor:d];
    if(!t)
    {
      if(errcode_ret) *errcode_ret = CL_MEM_OBJECT_ALLOCATION_FAILURE;
      return NULL;
    }
    MCLMem *m = [MCLMem new];
    m->context = AS(MCLContext, context);
    m->flags = flags;
    m->type = CL_MEM_OBJECT_IMAGE2D;
    m->texture = t;
    m->format = *image_format;
    m->width = image_desc->image_width;
    m->height = image_desc->image_height;
    m->elsize = elsize;
    m->size = m->width * m->height * elsize;
    m->hostPtr = (flags & CL_MEM_USE_HOST_PTR) ? host_ptr : NULL;
    if(host_ptr)
    {
      // a one-off command buffer, waited for, so the image is ready for any queue
      static id<MTLCommandQueue> upload;
      static dispatch_once_t once;
      dispatch_once(&once, ^{ upload = [g_device->mtl newCommandQueue]; });
      MCLQueue *tmp = [MCLQueue new];
      tmp->queue = upload;
      const size_t origin[3] = { 0, 0, 0 }, region[3] = { m->width, m->height, 1 };
      blit_host_to_texture(tmp, m, origin, region, image_desc->image_row_pitch, host_ptr);
      id<MTLCommandBuffer> cb = q_flush(tmp);
      [cb waitUntilCompleted];
    }
    if(errcode_ret) *errcode_ret = CL_SUCCESS;
    return (cl_mem)retain_out(m);
  }
}

cl_int clReleaseMemObject(cl_mem memobj)
{
  return release_obj(memobj, [MCLMem class], CL_INVALID_MEM_OBJECT);
}

cl_int clGetMemObjectInfo(cl_mem memobj, cl_mem_info param_name, size_t param_value_size, void *param_value,
                          size_t *param_value_size_ret)
{
  if(!is_a(memobj, [MCLMem class])) return CL_INVALID_MEM_OBJECT;
  MCLMem *m = AS(MCLMem, memobj);
  switch(param_name)
  {
    case CL_MEM_TYPE: RET(cl_mem_object_type, m->type);
    case CL_MEM_FLAGS: RET(cl_mem_flags, m->flags);
    case CL_MEM_SIZE: RET(size_t, m->size);
    case CL_MEM_HOST_PTR: RET(void *, m->hostPtr);
    case CL_MEM_MAP_COUNT: RET(cl_uint, (cl_uint)m->mapCount);
    case CL_MEM_REFERENCE_COUNT: RET(cl_uint, (cl_uint)m->refs);
    case CL_MEM_CONTEXT: RET(cl_context, (__bridge cl_context)m->context);
    case CL_MEM_ASSOCIATED_MEMOBJECT: RET(cl_mem, NULL);
    case CL_MEM_OFFSET: RET(size_t, 0);
    default: return CL_INVALID_VALUE;
  }
}

cl_int clGetImageInfo(cl_mem image, cl_image_info param_name, size_t param_value_size, void *param_value,
                      size_t *param_value_size_ret)
{
  if(!is_a(image, [MCLMem class]) || !AS(MCLMem, image)->texture) return CL_INVALID_MEM_OBJECT;
  MCLMem *m = AS(MCLMem, image);
  switch(param_name)
  {
    case CL_IMAGE_FORMAT: RET(cl_image_format, m->format);
    case CL_IMAGE_ELEMENT_SIZE: RET(size_t, m->elsize);
    case CL_IMAGE_ROW_PITCH: RET(size_t, m->width * m->elsize);
    case CL_IMAGE_SLICE_PITCH: RET(size_t, 0);
    case CL_IMAGE_WIDTH: RET(size_t, m->width);
    case CL_IMAGE_HEIGHT: RET(size_t, m->height);
    case CL_IMAGE_DEPTH: RET(size_t, 0);
    case CL_IMAGE_ARRAY_SIZE: RET(size_t, 0);
    case CL_IMAGE_BUFFER: RET(cl_mem, NULL);
    case CL_IMAGE_NUM_MIP_LEVELS: RET(cl_uint, 0);
    case CL_IMAGE_NUM_SAMPLES: RET(cl_uint, 0);
    default: return CL_INVALID_VALUE;
  }
}

// ------------------------------------------------------- transfers, copies

#define CHECK_QUEUE() \
  if(!is_a(command_queue, [MCLQueue class])) return CL_INVALID_COMMAND_QUEUE; \
  MCLQueue *q = AS(MCLQueue, command_queue);
#define CHECK_BUFFER(b) \
  if(!is_a(b, [MCLMem class]) || !AS(MCLMem, b)->buffer) return CL_INVALID_MEM_OBJECT;
#define CHECK_IMAGE(i) \
  if(!is_a(i, [MCLMem class]) || !AS(MCLMem, i)->texture) return CL_INVALID_MEM_OBJECT;

static BOOL region_ok(MCLMem *m, const size_t *origin, const size_t *region)
{
  return origin && region && region[0] && region[1] && region[2] == 1 && origin[2] == 0
         && origin[0] + region[0] <= m->width && origin[1] + region[1] <= m->height;
}

cl_int clEnqueueReadBuffer(cl_command_queue command_queue, cl_mem buffer, cl_bool blocking_read, size_t offset,
                           size_t size, void *ptr, cl_uint num_events_in_wait_list,
                           const cl_event *event_wait_list, cl_event *event)
{
  CHECK_QUEUE();
  CHECK_BUFFER(buffer);
  MCLMem *m = AS(MCLMem, buffer);
  if(!ptr || offset + size > m->size) return CL_INVALID_VALUE;
  cl_int err = wait_list(num_events_in_wait_list, event_wait_list);
  if(err != CL_SUCCESS) return err;
  @autoreleasepool
  {
    // in order: everything before has to finish; non-blocking reads are made blocking
    err = q_finish(q);
    memcpy(ptr, (const char *)m->buffer.contents + offset, size);
    make_event(q, CL_COMMAND_READ_BUFFER, nil, event);
  }
  return err;
}

cl_int clEnqueueWriteBuffer(cl_command_queue command_queue, cl_mem buffer, cl_bool blocking_write, size_t offset,
                            size_t size, const void *ptr, cl_uint num_events_in_wait_list,
                            const cl_event *event_wait_list, cl_event *event)
{
  CHECK_QUEUE();
  CHECK_BUFFER(buffer);
  MCLMem *m = AS(MCLMem, buffer);
  if(!ptr || offset + size > m->size) return CL_INVALID_VALUE;
  cl_int err = wait_list(num_events_in_wait_list, event_wait_list);
  if(err != CL_SUCCESS) return err;
  @autoreleasepool
  {
    LOCK();
    if(q_idle(q))
    {
      // nothing in flight can touch the buffer: write straight into it
      memcpy((char *)m->buffer.contents + offset, ptr, size);
      make_event(q, CL_COMMAND_WRITE_BUFFER, nil, event);
    }
    else
    {
      id<MTLBuffer> staging = [g_device->mtl newBufferWithBytes:ptr length:size options:MTLResourceStorageModeShared];
      [q_blit(q) copyFromBuffer:staging sourceOffset:0 toBuffer:m->buffer destinationOffset:offset size:size];
      make_event(q, CL_COMMAND_WRITE_BUFFER, q->cur, event);
      q_after_command(q);
    }
    UNLOCK();
  }
  return CL_SUCCESS;
}

cl_int clEnqueueReadImage(cl_command_queue command_queue, cl_mem image, cl_bool blocking_read,
                          const size_t *origin, const size_t *region, size_t row_pitch, size_t slice_pitch,
                          void *ptr, cl_uint num_events_in_wait_list, const cl_event *event_wait_list,
                          cl_event *event)
{
  CHECK_QUEUE();
  CHECK_IMAGE(image);
  MCLMem *m = AS(MCLMem, image);
  if(!ptr || !region_ok(m, origin, region)) return CL_INVALID_VALUE;
  const size_t rowbytes = region[0] * m->elsize;
  if(row_pitch == 0) row_pitch = rowbytes;
  if(row_pitch < rowbytes) return CL_INVALID_VALUE;
  cl_int err = wait_list(num_events_in_wait_list, event_wait_list);
  if(err != CL_SUCCESS) return err;
  @autoreleasepool
  {
    const size_t bytes = row_pitch * (region[1] - 1) + rowbytes;
    id<MTLBuffer> staging = [g_device->mtl newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    LOCK();
    [q_blit(q) copyFromTexture:m->texture
                   sourceSlice:0
                   sourceLevel:0
                  sourceOrigin:MTLOriginMake(origin[0], origin[1], 0)
                    sourceSize:MTLSizeMake(region[0], region[1], 1)
                      toBuffer:staging
             destinationOffset:0
        destinationBytesPerRow:row_pitch
      destinationBytesPerImage:row_pitch * region[1]];
    q->pending++;
    UNLOCK();
    err = q_finish(q);
    if(row_pitch == rowbytes)
      memcpy(ptr, staging.contents, bytes);
    else
      for(size_t y = 0; y < region[1]; y++)
        memcpy((char *)ptr + y * row_pitch, (const char *)staging.contents + y * row_pitch, rowbytes);
    make_event(q, CL_COMMAND_READ_IMAGE, nil, event);
  }
  return err;
}

cl_int clEnqueueWriteImage(cl_command_queue command_queue, cl_mem image, cl_bool blocking_write,
                           const size_t *origin, const size_t *region, size_t input_row_pitch,
                           size_t input_slice_pitch, const void *ptr, cl_uint num_events_in_wait_list,
                           const cl_event *event_wait_list, cl_event *event)
{
  CHECK_QUEUE();
  CHECK_IMAGE(image);
  MCLMem *m = AS(MCLMem, image);
  if(!ptr || !region_ok(m, origin, region)) return CL_INVALID_VALUE;
  if(input_row_pitch && input_row_pitch < region[0] * m->elsize) return CL_INVALID_VALUE;
  cl_int err = wait_list(num_events_in_wait_list, event_wait_list);
  if(err != CL_SUCCESS) return err;
  @autoreleasepool
  {
    // the host data is copied into a staging buffer now, so the call never
    // needs to block, whatever blocking_write says
    LOCK();
    blit_host_to_texture(q, m, origin, region, input_row_pitch, ptr);
    make_event(q, CL_COMMAND_WRITE_IMAGE, q->cur, event);
    q_after_command(q);
    UNLOCK();
  }
  return CL_SUCCESS;
}

cl_int clEnqueueCopyBuffer(cl_command_queue command_queue, cl_mem src_buffer, cl_mem dst_buffer, size_t src_offset,
                           size_t dst_offset, size_t size, cl_uint num_events_in_wait_list,
                           const cl_event *event_wait_list, cl_event *event)
{
  CHECK_QUEUE();
  CHECK_BUFFER(src_buffer);
  CHECK_BUFFER(dst_buffer);
  MCLMem *s = AS(MCLMem, src_buffer), *d = AS(MCLMem, dst_buffer);
  if(size == 0 || src_offset + size > s->size || dst_offset + size > d->size) return CL_INVALID_VALUE;
  cl_int err = wait_list(num_events_in_wait_list, event_wait_list);
  if(err != CL_SUCCESS) return err;
  @autoreleasepool
  {
    LOCK();
    [q_blit(q) copyFromBuffer:s->buffer sourceOffset:src_offset toBuffer:d->buffer destinationOffset:dst_offset size:size];
    make_event(q, CL_COMMAND_COPY_BUFFER, q->cur, event);
    q_after_command(q);
    UNLOCK();
  }
  return CL_SUCCESS;
}

cl_int clEnqueueCopyImage(cl_command_queue command_queue, cl_mem src_image, cl_mem dst_image,
                          const size_t *src_origin, const size_t *dst_origin, const size_t *region,
                          cl_uint num_events_in_wait_list, const cl_event *event_wait_list, cl_event *event)
{
  CHECK_QUEUE();
  CHECK_IMAGE(src_image);
  CHECK_IMAGE(dst_image);
  MCLMem *s = AS(MCLMem, src_image), *d = AS(MCLMem, dst_image);
  if(!region_ok(s, src_origin, region) || !region_ok(d, dst_origin, region)) return CL_INVALID_VALUE;
  if(s->texture.pixelFormat != d->texture.pixelFormat) return CL_IMAGE_FORMAT_MISMATCH;
  cl_int err = wait_list(num_events_in_wait_list, event_wait_list);
  if(err != CL_SUCCESS) return err;
  @autoreleasepool
  {
    LOCK();
    [q_blit(q) copyFromTexture:s->texture
                   sourceSlice:0
                   sourceLevel:0
                  sourceOrigin:MTLOriginMake(src_origin[0], src_origin[1], 0)
                    sourceSize:MTLSizeMake(region[0], region[1], 1)
                     toTexture:d->texture
              destinationSlice:0
              destinationLevel:0
             destinationOrigin:MTLOriginMake(dst_origin[0], dst_origin[1], 0)];
    make_event(q, CL_COMMAND_COPY_IMAGE, q->cur, event);
    q_after_command(q);
    UNLOCK();
  }
  return CL_SUCCESS;
}

cl_int clEnqueueCopyImageToBuffer(cl_command_queue command_queue, cl_mem src_image, cl_mem dst_buffer,
                                  const size_t *src_origin, const size_t *region, size_t dst_offset,
                                  cl_uint num_events_in_wait_list, const cl_event *event_wait_list,
                                  cl_event *event)
{
  CHECK_QUEUE();
  CHECK_IMAGE(src_image);
  CHECK_BUFFER(dst_buffer);
  MCLMem *s = AS(MCLMem, src_image), *d = AS(MCLMem, dst_buffer);
  if(!region_ok(s, src_origin, region)) return CL_INVALID_VALUE;
  const size_t rowbytes = region[0] * s->elsize;
  if(dst_offset + rowbytes * region[1] > d->size) return CL_INVALID_VALUE;
  cl_int err = wait_list(num_events_in_wait_list, event_wait_list);
  if(err != CL_SUCCESS) return err;
  @autoreleasepool
  {
    LOCK();
    [q_blit(q) copyFromTexture:s->texture
                   sourceSlice:0
                   sourceLevel:0
                  sourceOrigin:MTLOriginMake(src_origin[0], src_origin[1], 0)
                    sourceSize:MTLSizeMake(region[0], region[1], 1)
                      toBuffer:d->buffer
             destinationOffset:dst_offset
        destinationBytesPerRow:rowbytes
      destinationBytesPerImage:rowbytes * region[1]];
    make_event(q, CL_COMMAND_COPY_IMAGE_TO_BUFFER, q->cur, event);
    q_after_command(q);
    UNLOCK();
  }
  return CL_SUCCESS;
}

cl_int clEnqueueCopyBufferToImage(cl_command_queue command_queue, cl_mem src_buffer, cl_mem dst_image,
                                  size_t src_offset, const size_t *dst_origin, const size_t *region,
                                  cl_uint num_events_in_wait_list, const cl_event *event_wait_list,
                                  cl_event *event)
{
  CHECK_QUEUE();
  CHECK_BUFFER(src_buffer);
  CHECK_IMAGE(dst_image);
  MCLMem *s = AS(MCLMem, src_buffer), *d = AS(MCLMem, dst_image);
  if(!region_ok(d, dst_origin, region)) return CL_INVALID_VALUE;
  const size_t rowbytes = region[0] * d->elsize;
  if(src_offset + rowbytes * region[1] > s->size) return CL_INVALID_VALUE;
  cl_int err = wait_list(num_events_in_wait_list, event_wait_list);
  if(err != CL_SUCCESS) return err;
  @autoreleasepool
  {
    LOCK();
    [q_blit(q) copyFromBuffer:s->buffer
                 sourceOffset:src_offset
            sourceBytesPerRow:rowbytes
          sourceBytesPerImage:rowbytes * region[1]
                   sourceSize:MTLSizeMake(region[0], region[1], 1)
                    toTexture:d->texture
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(dst_origin[0], dst_origin[1], 0)];
    make_event(q, CL_COMMAND_COPY_BUFFER_TO_IMAGE, q->cur, event);
    q_after_command(q);
    UNLOCK();
  }
  return CL_SUCCESS;
}

void *clEnqueueMapBuffer(cl_command_queue command_queue, cl_mem buffer, cl_bool blocking_map, cl_map_flags map_flags,
                         size_t offset, size_t size, cl_uint num_events_in_wait_list,
                         const cl_event *event_wait_list, cl_event *event, cl_int *errcode_ret)
{
  cl_int err = CL_SUCCESS;
  if(!is_a(command_queue, [MCLQueue class])) err = CL_INVALID_COMMAND_QUEUE;
  else if(!is_a(buffer, [MCLMem class]) || !AS(MCLMem, buffer)->buffer) err = CL_INVALID_MEM_OBJECT;
  else if(offset + size > AS(MCLMem, buffer)->size || size == 0) err = CL_INVALID_VALUE;
  else err = wait_list(num_events_in_wait_list, event_wait_list);
  if(err != CL_SUCCESS)
  {
    if(errcode_ret) *errcode_ret = err;
    return NULL;
  }
  MCLQueue *q = AS(MCLQueue, command_queue);
  MCLMem *m = AS(MCLMem, buffer);
  @autoreleasepool
  {
    // shared storage: the buffer's own memory is the mapping
    err = q_finish(q);
    LOCK();
    m->mapCount++;
    UNLOCK();
    make_event(q, CL_COMMAND_MAP_BUFFER, nil, event);
  }
  if(errcode_ret) *errcode_ret = err;
  return (char *)m->buffer.contents + offset;
}

cl_int clEnqueueUnmapMemObject(cl_command_queue command_queue, cl_mem memobj, void *mapped_ptr,
                               cl_uint num_events_in_wait_list, const cl_event *event_wait_list, cl_event *event)
{
  CHECK_QUEUE();
  if(!is_a(memobj, [MCLMem class])) return CL_INVALID_MEM_OBJECT;
  MCLMem *m = AS(MCLMem, memobj);
  if(!m->buffer || !mapped_ptr) return CL_INVALID_VALUE;
  cl_int err = wait_list(num_events_in_wait_list, event_wait_list);
  if(err != CL_SUCCESS) return err;
  LOCK();
  if(m->mapCount > 0) m->mapCount--;
  UNLOCK();
  @autoreleasepool
  {
    make_event(q, CL_COMMAND_UNMAP_MEM_OBJECT, nil, event);
  }
  return CL_SUCCESS;
}

// ----------------------------------------------------------------- programs

// .cl file contents of a kernel directory, by file name without .cl
static NSDictionary *kernel_sources(NSString *dir)
{
  static NSMutableDictionary *cache;
  if(!cache) cache = [NSMutableDictionary new];
  NSDictionary *d = cache[dir];
  if(d) return d;
  NSMutableDictionary *m = [NSMutableDictionary new];
  for(NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil])
  {
    if(![f hasSuffix:@".cl"]) continue;
    NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:f]];
    if(data) m[[f stringByDeletingPathExtension]] = data;
  }
  cache[dir] = m;
  return m;
}

// the -I directory from the build options, with darktable's "\ " escapes undone
static NSString *include_dir(const char *options)
{
  if(!options) return nil;
  const char *p = strstr(options, "-I");
  while(p && p != options && p[-1] != ' ') p = strstr(p + 2, "-I");
  if(!p) return nil;
  p += 2;
  while(*p == ' ') p++;
  NSMutableString *s = [NSMutableString new];
  const BOOL quoted = *p == '"';
  if(quoted) p++;
  for(; *p; p++)
  {
    if(quoted && *p == '"') break;
    if(!quoted && *p == ' ') break;
    if(*p == '\\' && p[1])
    {
      p++;
    }
    [s appendFormat:@"%c", *p];
  }
  return s.length ? s : nil;
}

static NSString *metal_dir(NSString *kerneldir)
{
  const char *e = getenv("DT_METALCL_KERNELS");
  if(e && *e) return [NSString stringWithUTF8String:e];
  if(!kerneldir) return nil;
  return [[kerneldir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"metal-kernels"];
}

static cl_program clCreateProgramWithSource_impl(cl_context context, cl_uint count, const char **strings, const size_t *lengths,
                                     cl_int *errcode_ret)
{
  if(!is_a(context, [MCLContext class]))
  {
    if(errcode_ret) *errcode_ret = CL_INVALID_CONTEXT;
    return NULL;
  }
  if(count == 0 || !strings)
  {
    if(errcode_ret) *errcode_ret = CL_INVALID_VALUE;
    return NULL;
  }
  NSMutableData *src = [NSMutableData new];
  for(cl_uint i = 0; i < count; i++)
  {
    if(!strings[i])
    {
      if(errcode_ret) *errcode_ret = CL_INVALID_VALUE;
      return NULL;
    }
    const size_t n = lengths && lengths[i] ? lengths[i] : strlen(strings[i]);
    [src appendBytes:strings[i] length:n];
  }
  MCLProgram *p = [MCLProgram new];
  p->context = AS(MCLContext, context);
  p->source = src;
  p->status = CL_BUILD_NONE;
  p->pipelines = [NSMutableDictionary new];
  if(errcode_ret) *errcode_ret = CL_SUCCESS;
  return (cl_program)retain_out(p);
}

// autorelease pool: darktable's threads have none
cl_program clCreateProgramWithSource(cl_context context, cl_uint count, const char **strings, const size_t *lengths,
                                     cl_int *errcode_ret)
{
  @autoreleasepool
  {
    return clCreateProgramWithSource_impl(context, count, strings, lengths, errcode_ret);
  }
}

static NSString *const kBinaryPrefix = @"metalcl1:";

static cl_program clCreateProgramWithBinary_impl(cl_context context, cl_uint num_devices, const cl_device_id *device_list,
                                     const size_t *lengths, const unsigned char **binaries, cl_int *binary_status,
                                     cl_int *errcode_ret)
{
  cl_int err = CL_SUCCESS;
  if(!is_a(context, [MCLContext class])) err = CL_INVALID_CONTEXT;
  else if(num_devices != 1 || !device_list || !lengths || !binaries || !binaries[0]) err = CL_INVALID_VALUE;
  else if(device_list[0] != (cl_device_id)g_device_id) err = CL_INVALID_DEVICE;
  NSString *name = nil;
  if(err == CL_SUCCESS)
  {
    NSString *s = [[NSString alloc] initWithBytes:binaries[0] length:lengths[0] encoding:NSUTF8StringEncoding];
    if(![s hasPrefix:kBinaryPrefix])
      err = CL_INVALID_BINARY;
    else
      name = [s substringFromIndex:kBinaryPrefix.length];
    if(binary_status) binary_status[0] = err;
  }
  if(errcode_ret) *errcode_ret = err;
  if(err != CL_SUCCESS) return NULL;
  MCLProgram *p = [MCLProgram new];
  p->context = AS(MCLContext, context);
  p->name = name;
  p->status = CL_BUILD_NONE;
  p->pipelines = [NSMutableDictionary new];
  return (cl_program)retain_out(p);
}

// autorelease pool: darktable's threads have none
cl_program clCreateProgramWithBinary(cl_context context, cl_uint num_devices, const cl_device_id *device_list,
                                     const size_t *lengths, const unsigned char **binaries, cl_int *binary_status,
                                     cl_int *errcode_ret)
{
  @autoreleasepool
  {
    return clCreateProgramWithBinary_impl(context, num_devices, device_list, lengths, binaries, binary_status, errcode_ret);
  }
}

static MTLCompileOptions *compile_options(const char *options)
{
  MTLCompileOptions *o = [MTLCompileOptions new];
  const char *e = getenv("DT_METALCL_MATH");
  NSString *mode = e ? [NSString stringWithUTF8String:e]
                     : (options && strstr(options, "-cl-fast-relaxed-math") ? @"fast" : @"relaxed");
  if(@available(macOS 15.0, *))
  {
    if([mode isEqualToString:@"fast"])
    {
      o.mathMode = MTLMathModeFast;
      o.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsFast;
    }
    else if([mode isEqualToString:@"safe"])
    {
      o.mathMode = MTLMathModeSafe;
      o.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
    }
    else
    {
      // like OpenCL without -cl-fast-relaxed-math: reassociation allowed,
      // but NaN and infinity honoured and full-precision library functions
      o.mathMode = MTLMathModeRelaxed;
      o.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
    }
  }
  else
  {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    o.fastMathEnabled = ![mode isEqualToString:@"safe"];
#pragma clang diagnostic pop
  }
  return o;
}

cl_int clBuildProgram(cl_program program, cl_uint num_devices, const cl_device_id *device_list, const char *options,
                      void (*pfn_notify)(cl_program, void *), void *user_data)
{
  if(!is_a(program, [MCLProgram class])) return CL_INVALID_PROGRAM;
  if((num_devices == 0) != (device_list == NULL)) return CL_INVALID_VALUE;
  if(num_devices && device_list[0] != (cl_device_id)g_device_id) return CL_INVALID_DEVICE;
  MCLProgram *p = AS(MCLProgram, program);
  @autoreleasepool
  {
    NSString *kdir = include_dir(options);
    NSMutableString *log = [NSMutableString new];
    p->options = options ? [NSString stringWithUTF8String:options] : @"";

    // which darktable kernel file is this?
    if(!p->name)
    {
      LOCK();
      NSDictionary *files = kdir ? kernel_sources(kdir) : nil;
      UNLOCK();
      for(NSString *n in files)
        if([files[n] isEqualToData:p->source])
        {
          p->name = n;
          break;
        }
      if(!p->name)
      {
        [log appendFormat:@"MetalCL: source matches no .cl file in '%@'\n", kdir ?: @"(no -I option)"];
        p->log = log;
        p->status = CL_BUILD_ERROR;
        err_log("%s", log.UTF8String);
        return CL_BUILD_PROGRAM_FAILURE;
      }
    }

    NSString *mdir = metal_dir(kdir);
    NSString *mpath = [mdir stringByAppendingPathComponent:[p->name stringByAppendingPathExtension:@"metal"]];
    NSString *jpath = [mdir stringByAppendingPathComponent:[p->name stringByAppendingPathExtension:@"json"]];
    NSString *msrc = [NSString stringWithContentsOfFile:mpath encoding:NSUTF8StringEncoding error:nil];
    NSData *json = [NSData dataWithContentsOfFile:jpath];
    NSDictionary *map = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    if(!msrc || ![map isKindOfClass:[NSDictionary class]])
    {
      [log appendFormat:@"MetalCL: no Metal translation for '%@' (looked for %@ and %@)\n", p->name, mpath, jpath];
      p->log = log;
      p->status = CL_BUILD_ERROR;
      err_log("%s", log.UTF8String);
      return CL_BUILD_PROGRAM_FAILURE;
    }
    p->argmap = map;

    // compile in the background: darktable builds every program at start-up,
    // and the first kernel creation waits only for its own program
    if(!p->compiling)
    {
      p->compiling = dispatch_group_create();
      dispatch_group_enter(p->compiling);
      MCLProgram *pp = p;
      const double t0 = CFAbsoluteTimeGetCurrent();
      [g_device->mtl newLibraryWithSource:msrc
                                  options:compile_options(options)
                        completionHandler:^(id<MTLLibrary> lib, NSError *error) {
                          pp->library = lib;
                          if(!lib) pp->compileError = error;
                          dbg("compiled %s in %.0f ms%s", pp->name.UTF8String,
                              (CFAbsoluteTimeGetCurrent() - t0) * 1000, lib ? "" : " (FAILED)");
                          dispatch_group_leave(pp->compiling);
                        }];
    }
    [log appendFormat:@"MetalCL: %@ from %@\n", p->name, mpath];
    p->log = log;
    p->status = CL_BUILD_SUCCESS;
    dbg("build %s", p->name.UTF8String);
  }
  if(pfn_notify) pfn_notify(program, user_data);
  return CL_SUCCESS;
}

static cl_int clGetProgramBuildInfo_impl(cl_program program, cl_device_id device, cl_program_build_info param_name,
                             size_t param_value_size, void *param_value, size_t *param_value_size_ret)
{
  if(!is_a(program, [MCLProgram class])) return CL_INVALID_PROGRAM;
  if(device != (cl_device_id)g_device_id) return CL_INVALID_DEVICE;
  MCLProgram *p = AS(MCLProgram, program);
  switch(param_name)
  {
    case CL_PROGRAM_BUILD_STATUS: RET(cl_build_status, p->status);
    case CL_PROGRAM_BUILD_OPTIONS: RETS(p->options ? p->options.UTF8String : "");
    case CL_PROGRAM_BUILD_LOG: RETS(p->log ? p->log.UTF8String : "");
    case CL_PROGRAM_BINARY_TYPE:
      RET(cl_program_binary_type, p->status == CL_BUILD_SUCCESS ? CL_PROGRAM_BINARY_TYPE_EXECUTABLE
                                                                : CL_PROGRAM_BINARY_TYPE_NONE);
    default: return CL_INVALID_VALUE;
  }
}

// autorelease pool: darktable's threads have none
cl_int clGetProgramBuildInfo(cl_program program, cl_device_id device, cl_program_build_info param_name,
                             size_t param_value_size, void *param_value, size_t *param_value_size_ret)
{
  @autoreleasepool
  {
    return clGetProgramBuildInfo_impl(program, device, param_name, param_value_size, param_value, param_value_size_ret);
  }
}

static cl_int clGetProgramInfo_impl(cl_program program, cl_program_info param_name, size_t param_value_size,
                        void *param_value, size_t *param_value_size_ret)
{
  if(!is_a(program, [MCLProgram class])) return CL_INVALID_PROGRAM;
  MCLProgram *p = AS(MCLProgram, program);
  // the "binary" just names the program: the Metal source is read and
  // compiled again when it's loaded back
  NSData *bin = [[kBinaryPrefix stringByAppendingString:p->name ?: @""] dataUsingEncoding:NSUTF8StringEncoding];
  switch(param_name)
  {
    case CL_PROGRAM_REFERENCE_COUNT: RET(cl_uint, (cl_uint)p->refs);
    case CL_PROGRAM_CONTEXT: RET(cl_context, (__bridge cl_context)p->context);
    case CL_PROGRAM_NUM_DEVICES: RET(cl_uint, 1);
    case CL_PROGRAM_DEVICES: RET(cl_device_id, (cl_device_id)g_device_id);
    case CL_PROGRAM_SOURCE:
    {
      if(!p->source) RETS("");
      NSMutableData *s = [p->source mutableCopy];
      [s appendBytes:"" length:1];
      return ret_info(s.bytes, s.length, param_value_size, param_value, param_value_size_ret);
    }
    case CL_PROGRAM_BINARY_SIZES:
      if(!p->name) return CL_INVALID_PROGRAM_EXECUTABLE;
      RET(size_t, bin.length);
    case CL_PROGRAM_BINARIES:
    {
      if(!p->name) return CL_INVALID_PROGRAM_EXECUTABLE;
      if(param_value)
      {
        if(param_value_size < sizeof(unsigned char *)) return CL_INVALID_VALUE;
        unsigned char *dst = ((unsigned char **)param_value)[0];
        if(dst) memcpy(dst, bin.bytes, bin.length);
      }
      if(param_value_size_ret) *param_value_size_ret = sizeof(unsigned char *);
      return CL_SUCCESS;
    }
    case CL_PROGRAM_NUM_KERNELS: RET(size_t, p->argmap.count);
    case CL_PROGRAM_KERNEL_NAMES:
      RETS([[p->argmap.allKeys componentsJoinedByString:@";"] UTF8String] ?: "");
    default: return CL_INVALID_VALUE;
  }
}

// autorelease pool: darktable's threads have none
cl_int clGetProgramInfo(cl_program program, cl_program_info param_name, size_t param_value_size,
                        void *param_value, size_t *param_value_size_ret)
{
  @autoreleasepool
  {
    return clGetProgramInfo_impl(program, param_name, param_value_size, param_value, param_value_size_ret);
  }
}

cl_int clReleaseProgram(cl_program program)
{
  return release_obj(program, [MCLProgram class], CL_INVALID_PROGRAM);
}

// ------------------------------------------------------------------ kernels

// exact OpenCL sizes of the scalar types in the argument maps; anything else
// (enum typedefs, structs) is checked against the room in the struct
static size_t scalar_size(NSString *type)
{
  static NSDictionary *sizes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    sizes = @{ @"int" : @4, @"uint" : @4, @"unsigned int" : @4, @"unsigned" : @4, @"float" : @4,
               @"short" : @2, @"ushort" : @2, @"char" : @1, @"uchar" : @1, @"char2" : @2,
               @"float2" : @8, @"int2" : @8, @"uint2" : @8, @"float3" : @16, @"int3" : @16,
               @"float4" : @16, @"int4" : @16, @"uint4" : @16, @"size_t" : @8, @"long" : @8, @"ulong" : @8 };
  });
  return [sizes[type] unsignedLongValue];
}
static size_t scalar_align(NSString *type, size_t size)
{
  if(size == 16 || [type hasSuffix:@"3"]) return 16;
  if(size == 0) return 4;
  if([type isEqualToString:@"char2"]) return 2;
  return size;
}

static MCLKernelInfo *make_kernel_info(MCLProgram *p, NSString *name, cl_int *err)
{
  NSArray *map = p->argmap[name];
  if(![map isKindOfClass:[NSArray class]])
  {
    *err = CL_INVALID_KERNEL_NAME;
    return nil;
  }
  // wait for the background compile of this program
  dispatch_group_wait(p->compiling, DISPATCH_TIME_FOREVER);
  if(!p->library)
  {
    err_log("%s.metal does not compile: %s", p->name.UTF8String,
            p->compileError.localizedDescription.UTF8String ?: "?");
    *err = CL_INVALID_PROGRAM_EXECUTABLE;
    return nil;
  }
  id<MTLFunction> fn = [p->library newFunctionWithName:name];
  if(!fn)
  {
    *err = CL_INVALID_KERNEL_NAME;
    return nil;
  }
  NSError *error = nil;
  MTLComputePipelineReflection *refl = nil;
  MTLComputePipelineDescriptor *desc = [MTLComputePipelineDescriptor new];
  desc.computeFunction = fn;
  desc.label = name;
  id<MTLComputePipelineState> ps = [g_device->mtl newComputePipelineStateWithDescriptor:desc
                                                                                options:MTLPipelineOptionBindingInfo
                                                                             reflection:&refl
                                                                                  error:&error];
  if(!ps)
  {
    err_log("pipeline for %s failed: %s", name.UTF8String, error.localizedDescription.UTF8String ?: "?");
    *err = CL_INVALID_KERNEL;
    return nil;
  }

  // the argument struct at buffer 0, and which textures are texture2d<uint>
  id<MTLBufferBinding> structBinding = nil;
  NSMutableSet *uintTextures = [NSMutableSet new];
  for(id<MTLBinding> b in refl.bindings)
  {
    if(b.type == MTLBindingTypeBuffer && b.index == 0) structBinding = (id<MTLBufferBinding>)b;
    if(b.type == MTLBindingTypeTexture && ((id<MTLTextureBinding>)b).textureDataType == MTLDataTypeUInt)
      [uintTextures addObject:@(b.index)];
  }
  NSArray<MTLStructMember *> *members = structBinding.bufferStructType.members;

  MCLKernelInfo *info = [MCLKernelInfo new];
  info->pipeline = ps;
  info->nargs = (int)map.count;
  info->args = calloc(map.count ? map.count : 1, sizeof(arg_info_t));

  // scalars: layout from reflection if the struct is there, else computed
  // with Metal's rules (alignment = size up to 16, float3 counts as 16)
  size_t off = 0, maxAlign = 4;
  int nfields = 0;
  for(NSDictionary *a in map)
    if([a[@"kind"] isEqualToString:@"scalar"]) nfields++;
  const BOOL useRefl = members.count == (NSUInteger)nfields && nfields > 0;
  for(NSUInteger i = 0; i < map.count; i++)
  {
    NSDictionary *a = map[i];
    arg_info_t *ai = info->args + i;
    NSString *kind = a[@"kind"];
    if([kind isEqualToString:@"texture"])
    {
      ai->kind = ARG_TEXTURE;
      ai->slot = [a[@"slot"] intValue];
      ai->write = [a[@"write"] boolValue];
      ai->uintTexture = [uintTextures containsObject:@(ai->slot)];
    }
    else if([kind isEqualToString:@"buffer"])
    {
      ai->kind = ARG_BUFFER;
      ai->slot = [a[@"slot"] intValue];
    }
    else if([kind isEqualToString:@"local"])
    {
      ai->kind = ARG_LOCAL;
      ai->slot = [a[@"slot"] intValue];
    }
    else
    {
      ai->kind = ARG_SCALAR;
      ai->slot = [a[@"field"] intValue];
      ai->expect = scalar_size(a[@"type"]);
      if(useRefl)
        ai->offset = members[ai->slot].offset;
      else
      {
        const size_t sz = ai->expect ? ai->expect : 4;
        const size_t al = scalar_align(a[@"type"], ai->expect);
        off = (off + al - 1) / al * al;
        ai->offset = off;
        ai->span = sz;
        off += sz;
        maxAlign = MAX(maxAlign, al);
      }
    }
  }
  if(useRefl)
  {
    info->structSize = structBinding.bufferDataSize;
    // span of each member: up to the next member's offset, or the end
    for(int i = 0; i < info->nargs; i++)
    {
      arg_info_t *ai = info->args + i;
      if(ai->kind != ARG_SCALAR) continue;
      size_t next = info->structSize;
      for(int j = 0; j < info->nargs; j++)
        if(info->args[j].kind == ARG_SCALAR && info->args[j].offset > ai->offset)
          next = MIN(next, info->args[j].offset);
      ai->span = next - ai->offset;
    }
  }
  else
    info->structSize = nfields ? (off + maxAlign - 1) / maxAlign * maxAlign : 0;
  return info;
}

cl_kernel clCreateKernel(cl_program program, const char *kernel_name, cl_int *errcode_ret)
{
  cl_int err = CL_SUCCESS;
  if(!is_a(program, [MCLProgram class])) err = CL_INVALID_PROGRAM;
  else if(!kernel_name) err = CL_INVALID_VALUE;
  else if(AS(MCLProgram, program)->status != CL_BUILD_SUCCESS) err = CL_INVALID_PROGRAM_EXECUTABLE;
  if(err != CL_SUCCESS)
  {
    if(errcode_ret) *errcode_ret = err;
    return NULL;
  }
  MCLProgram *p = AS(MCLProgram, program);
  @autoreleasepool
  {
    NSString *name = [NSString stringWithUTF8String:kernel_name];
    LOCK();
    MCLKernelInfo *info = p->pipelines[name];
    UNLOCK();
    if(!info)
    {
      // compiled outside the lock; a race only builds the same pipeline twice
      info = make_kernel_info(p, name, &err);
      if(!info)
      {
        if(errcode_ret) *errcode_ret = err;
        return NULL;
      }
      LOCK();
      if(p->pipelines[name]) info = p->pipelines[name];
      else p->pipelines[name] = info;
      UNLOCK();
    }
    MCLKernel *k = [MCLKernel new];
    k->program = p;
    k->name = name;
    k->info = info;
    k->mems = calloc(info->nargs + 1, sizeof(void *));
    k->localSizes = calloc(info->nargs + 1, sizeof(size_t));
    k->isSet = calloc(info->nargs + 1, sizeof(BOOL));
    k->argStruct = calloc(info->structSize + 16, 1);
    if(errcode_ret) *errcode_ret = CL_SUCCESS;
    return (cl_kernel)retain_out(k);
  }
}

cl_int clReleaseKernel(cl_kernel kernel)
{
  return release_obj(kernel, [MCLKernel class], CL_INVALID_KERNEL);
}

static cl_int clSetKernelArg_impl(cl_kernel kernel, cl_uint arg_index, size_t arg_size, const void *arg_value)
{
  if(!is_a(kernel, [MCLKernel class])) return CL_INVALID_KERNEL;
  MCLKernel *k = AS(MCLKernel, kernel);
  MCLKernelInfo *info = k->info;
  if(arg_index >= (cl_uint)info->nargs) return CL_INVALID_ARG_INDEX;
  const arg_info_t *ai = info->args + arg_index;
  cl_int err = CL_SUCCESS;
  LOCK();
  switch(ai->kind)
  {
    case ARG_TEXTURE:
    case ARG_BUFFER:
    {
      if(arg_size != sizeof(cl_mem))
      {
        err = CL_INVALID_ARG_SIZE;
        break;
      }
      const cl_mem m = arg_value ? *(const cl_mem *)arg_value : NULL;
      if(m)
      {
        if(!is_a(m, [MCLMem class])
           || (ai->kind == ARG_TEXTURE && !AS(MCLMem, m)->texture)
           || (ai->kind == ARG_BUFFER && !AS(MCLMem, m)->buffer))
        {
          err = CL_INVALID_MEM_OBJECT;
          break;
        }
        k->mems[arg_index] = (void *)m;
      }
      else
        k->mems[arg_index] = NULL;
      break;
    }
    case ARG_LOCAL:
      if(arg_value) err = CL_INVALID_ARG_VALUE;
      else if(arg_size == 0) err = CL_INVALID_ARG_SIZE;
      else k->localSizes[arg_index] = arg_size;
      break;
    case ARG_SCALAR:
      if(!arg_value) err = CL_INVALID_ARG_VALUE;
      else if(ai->expect ? arg_size != ai->expect : (arg_size == 0 || arg_size > ai->span)) err = CL_INVALID_ARG_SIZE;
      else memcpy(k->argStruct + ai->offset, arg_value, MIN(arg_size, ai->span));
      break;
  }
  if(err == CL_SUCCESS) k->isSet[arg_index] = YES;
  UNLOCK();
  if(err != CL_SUCCESS)
    err_log("clSetKernelArg %s arg %u (size %zu): error %d", k->name.UTF8String, arg_index, arg_size, err);
  return err;
}

// autorelease pool: darktable's threads have none
cl_int clSetKernelArg(cl_kernel kernel, cl_uint arg_index, size_t arg_size, const void *arg_value)
{
  @autoreleasepool
  {
    return clSetKernelArg_impl(kernel, arg_index, arg_size, arg_value);
  }
}

static cl_int clGetKernelInfo_impl(cl_kernel kernel, cl_kernel_info param_name, size_t param_value_size, void *param_value,
                       size_t *param_value_size_ret)
{
  if(!is_a(kernel, [MCLKernel class])) return CL_INVALID_KERNEL;
  MCLKernel *k = AS(MCLKernel, kernel);
  switch(param_name)
  {
    case CL_KERNEL_FUNCTION_NAME: RETS(k->name.UTF8String);
    case CL_KERNEL_NUM_ARGS: RET(cl_uint, (cl_uint)k->info->nargs);
    case CL_KERNEL_REFERENCE_COUNT: RET(cl_uint, (cl_uint)k->refs);
    case CL_KERNEL_CONTEXT: RET(cl_context, (__bridge cl_context)k->program->context);
    case CL_KERNEL_PROGRAM: RET(cl_program, (__bridge cl_program)k->program);
    case CL_KERNEL_ATTRIBUTES: RETS("");
    default: return CL_INVALID_VALUE;
  }
}

// autorelease pool: darktable's threads have none
cl_int clGetKernelInfo(cl_kernel kernel, cl_kernel_info param_name, size_t param_value_size, void *param_value,
                       size_t *param_value_size_ret)
{
  @autoreleasepool
  {
    return clGetKernelInfo_impl(kernel, param_name, param_value_size, param_value, param_value_size_ret);
  }
}

cl_int clGetKernelWorkGroupInfo(cl_kernel kernel, cl_device_id device, cl_kernel_work_group_info param_name,
                                size_t param_value_size, void *param_value, size_t *param_value_size_ret)
{
  if(!is_a(kernel, [MCLKernel class])) return CL_INVALID_KERNEL;
  if(device && device != (cl_device_id)g_device_id) return CL_INVALID_DEVICE;
  id<MTLComputePipelineState> ps = AS(MCLKernel, kernel)->info->pipeline;
  switch(param_name)
  {
    case CL_KERNEL_WORK_GROUP_SIZE: RET(size_t, ps.maxTotalThreadsPerThreadgroup);
    case CL_KERNEL_COMPILE_WORK_GROUP_SIZE:
    {
      const size_t s[3] = { 0, 0, 0 };
      return ret_info(s, sizeof(s), param_value_size, param_value, param_value_size_ret);
    }
    case CL_KERNEL_LOCAL_MEM_SIZE: RET(cl_ulong, ps.staticThreadgroupMemoryLength);
    case CL_KERNEL_PREFERRED_WORK_GROUP_SIZE_MULTIPLE: RET(size_t, ps.threadExecutionWidth);
    case CL_KERNEL_PRIVATE_MEM_SIZE: RET(cl_ulong, 0);
    default: return CL_INVALID_VALUE;
  }
}

cl_int clEnqueueNDRangeKernel(cl_command_queue command_queue, cl_kernel kernel, cl_uint work_dim,
                              const size_t *global_work_offset, const size_t *global_work_size,
                              const size_t *local_work_size, cl_uint num_events_in_wait_list,
                              const cl_event *event_wait_list, cl_event *event)
{
  CHECK_QUEUE();
  if(!is_a(kernel, [MCLKernel class])) return CL_INVALID_KERNEL;
  if(work_dim < 1 || work_dim > 3) return CL_INVALID_WORK_DIMENSION;
  if(!global_work_size) return CL_INVALID_GLOBAL_WORK_SIZE;
  MCLKernel *k = AS(MCLKernel, kernel);
  MCLKernelInfo *info = k->info;
  id<MTLComputePipelineState> ps = info->pipeline;

  size_t g[3] = { 1, 1, 1 }, l[3] = { 1, 1, 1 };
  for(cl_uint d = 0; d < work_dim; d++)
  {
    if(global_work_offset && global_work_offset[d]) return CL_INVALID_GLOBAL_OFFSET;
    g[d] = global_work_size[d];
    if(g[d] == 0) return CL_INVALID_GLOBAL_WORK_SIZE;
    if(local_work_size)
    {
      l[d] = local_work_size[d];
      if(l[d] == 0) return CL_INVALID_WORK_GROUP_SIZE;
    }
  }
  if(local_work_size)
  {
    if(l[0] * l[1] * l[2] > ps.maxTotalThreadsPerThreadgroup)
    {
      err_log("%s: work group %zux%zux%zu exceeds the pipeline's %lu threads", k->name.UTF8String, l[0], l[1],
              l[2], (unsigned long)ps.maxTotalThreadsPerThreadgroup);
      return CL_INVALID_WORK_GROUP_SIZE;
    }
  }
  else
  {
    // no local size: a sensible threadgroup, capped by the pipeline
    const size_t maxt = ps.maxTotalThreadsPerThreadgroup;
    if(work_dim == 1) l[0] = MIN((size_t)256, maxt);
    else
    {
      l[0] = 16;
      l[1] = MAX((size_t)1, MIN((size_t)16, maxt / 16));
    }
  }

  cl_int err = wait_list(num_events_in_wait_list, event_wait_list);
  if(err != CL_SUCCESS) return err;

  @autoreleasepool
  {
    LOCK();
    for(int i = 0; i < info->nargs; i++)
      if(!k->isSet[i])
      {
        UNLOCK();
        err_log("%s: argument %d not set", k->name.UTF8String, i);
        return CL_INVALID_KERNEL_ARGS;
      }
    size_t localTotal = 0;
    for(int i = 0; i < info->nargs; i++)
      if(info->args[i].kind == ARG_LOCAL) localTotal += (k->localSizes[i] + 15) & ~(size_t)15;
    if(localTotal + ps.staticThreadgroupMemoryLength > g_device->mtl.maxThreadgroupMemoryLength)
    {
      UNLOCK();
      err_log("%s: %zu bytes of local memory requested", k->name.UTF8String, localTotal);
      return CL_OUT_OF_RESOURCES;
    }

    id<MTLComputeCommandEncoder> enc = q_compute(q);
    [enc setComputePipelineState:ps];
    if(info->structSize) [enc setBytes:k->argStruct length:info->structSize atIndex:0];
    for(int i = 0; i < info->nargs; i++)
    {
      const arg_info_t *ai = info->args + i;
      MCLMem *m = k->mems[i] ? AS(MCLMem, k->mems[i]) : nil;
      switch(ai->kind)
      {
        case ARG_TEXTURE:
          [enc setTexture:m ? m->texture : (ai->uintTexture ? g_device->dummyUInt : g_device->dummyFloat)
                  atIndex:ai->slot];
          break;
        case ARG_BUFFER:
          [enc setBuffer:m ? m->buffer : g_device->dummyBuffer offset:0 atIndex:ai->slot];
          break;
        case ARG_LOCAL:
          [enc setThreadgroupMemoryLength:(k->localSizes[i] + 15) & ~(size_t)15 atIndex:ai->slot];
          break;
        case ARG_SCALAR: break;
      }
    }
    if(local_work_size)
    {
      // OpenCL semantics: whole work groups, the global size rounded up
      const MTLSize groups = MTLSizeMake((g[0] + l[0] - 1) / l[0], (g[1] + l[1] - 1) / l[1], (g[2] + l[2] - 1) / l[2]);
      [enc dispatchThreadgroups:groups threadsPerThreadgroup:MTLSizeMake(l[0], l[1], l[2])];
    }
    else
      [enc dispatchThreads:MTLSizeMake(g[0], g[1], g[2]) threadsPerThreadgroup:MTLSizeMake(l[0], l[1], l[2])];
    make_event(q, CL_COMMAND_NDRANGE_KERNEL, q->cur, event);
    q_after_command(q);
    UNLOCK();
  }
  return CL_SUCCESS;
}
