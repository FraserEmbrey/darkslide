/*
  darkroom-helper: runs the darktable engine headless for the native app.

  Protocol: one JSON object per line on stdin, one JSON reply per line on
  the original stdout. darktable's own logging is pushed to stderr so it
  can never corrupt the protocol stream.

  Rendered previews are written as BGRA8 into a memory-mapped frame file
  that the app maps too, so pixels never travel through the pipe.

  Commands:
    {"cmd":"open","path":"/x.ARW"}                  -> image size + module list
    {"cmd":"set","module":"exposure:0","field":"exposure","value":0.5}
    {"cmd":"enable","module":"exposure:0","on":true}
    {"cmd":"reset","module":"exposure:0"}
    {"cmd":"render","max":1600,"hdr":false}         -> frame width/height/ms
      "before":true renders the photo as it was when opened, for comparison
      "scale":1,"x":..,"y":..,"w":..,"h":.. renders a crop at that scale (zoom)
      SDR: BGRA8 in sRGB. HDR: RGBA float32, linear Rec.2020, unclipped, so
      values above 1.0 are highlights above SDR white (EDR convention).
    {"cmd":"save"}                                  -> writes the XMP sidecar
    {"cmd":"modules"}                               -> current module list
    {"cmd":"styles"}                                -> all styles in darktable's database
    {"cmd":"toneequal_fit"}                         -> fits the tone equalizer's mask to the photo
    {"cmd":"filmic_autotune"}                       -> filmic's "auto tune levels" over the whole image
    {"cmd":"export","path":"/out/name","format":"jpeg","quality":90,"bpp":8,"max":0,"icc":-1}
                                                     -> exports through darktable's disk storage;
                                                        the extension is added; replies with the file
    {"cmd":"apply_style","name":"..."}              -> appends a style to the edit, returns modules
    {"cmd":"add_instance","module":"rgbcurve:0","name":"channels"} -> a new instance after it

  GPL-3.0-or-later, as it links darktable.
*/

#include "common/colorspaces.h"
#include "common/darktable.h"
#include "common/database.h"
#include <sqlite3.h>
#include "common/film.h"
#include "common/image.h"
#include "common/image_cache.h"
#include "common/history.h"
#include "common/introspection.h"
#include "common/luminance_mask.h"
#include "imageio/imageio_module.h"
#include "common/iop_order.h"
#include "common/mipmap_cache.h"
#include "common/styles.h"
#include "common/ratings.h"
#include "common/metadata.h"
#include "common/tags.h"
#include "common/exif.h"
#include "develop/develop.h"
#include "develop/imageop.h"
#include "develop/blend.h"
#include "develop/masks.h"
#include "common/ras2vect.h"
#include "develop/pixelpipe_cache.h"
#include "develop/pixelpipe_hb.h"
#include "imageio/imageio_common.h"

#include <fcntl.h>
#include <json-glib/json-glib.h>
#include <stdio.h>
#include <sys/mman.h>
#include <lensfun.h>
#include <unistd.h>

// one image loaded into darktable: its develop state, pipe and input
typedef struct view_t
{
  gboolean loaded;
  dt_develop_t dev;
  dt_dev_pixelpipe_t pipe;
  dt_mipmap_buffer_t buf;
  gboolean dirty;           // params changed since the last render
  gboolean overridden;      // the pipe holds one render's overrides; resync before the next
} view_t;

typedef struct helper_t
{
  FILE *out;                // protocol channel (the original stdout)
  const char *frame_path;   // file shared with the app for preview pixels
  int frame_fd;
  void *frame_map;
  size_t frame_cap;

  dt_imgid_t imgid;
  view_t edit;              // the photo being edited
  view_t before;            // the photo as it was when opened, for comparison
  gboolean hdr;             // current output mode of the pipes
  // the photo is an HDR source (see _sync_hdr_white), as the app said on open
  gboolean hdr_source;
  // the module whose input histogram the app shows (a curve's); its commit
  // turns collection off outside darktable's preview pipe, so it's turned
  // back on before each render
  dt_iop_module_t *histogram_module;
} helper_t;

static helper_t H = { 0 };

// ---------------------------------------------------------------- replies

static void _reply(JsonBuilder *b)
{
  JsonGenerator *gen = json_generator_new();
  JsonNode *root = json_builder_get_root(b);
  json_generator_set_root(gen, root);
  gchar *s = json_generator_to_data(gen, NULL);
  fprintf(H.out, "%s\n", s);
  fflush(H.out);
  g_free(s);
  json_node_unref(root);
  g_object_unref(gen);
  g_object_unref(b);
}

static JsonBuilder *_ok(void)
{
  JsonBuilder *b = json_builder_new();
  json_builder_begin_object(b);
  json_builder_set_member_name(b, "ok");
  json_builder_add_boolean_value(b, TRUE);
  // every reply carries the edit's history position, which the app's undo
  // stack records and steps back to
  if(H.edit.loaded)
  {
    json_builder_set_member_name(b, "historyEnd");
    json_builder_add_int_value(b, H.edit.dev.history_end);
  }
  return b;
}

static void _ok_done(JsonBuilder *b)
{
  json_builder_end_object(b);
  _reply(b);
}

static void _error(const char *msg)
{
  JsonBuilder *b = json_builder_new();
  json_builder_begin_object(b);
  json_builder_set_member_name(b, "ok");
  json_builder_add_boolean_value(b, FALSE);
  json_builder_set_member_name(b, "error");
  json_builder_add_string_value(b, msg);
  json_builder_end_object(b);
  _reply(b);
}

// --------------------------------------------------------- module lookup

// modules are addressed as "op:multi_priority", e.g. "exposure:0"
static gchar *_module_key(const dt_iop_module_t *m)
{
  return g_strdup_printf("%s:%d", m->op, m->multi_priority);
}

static dt_iop_module_t *_find_module(const char *key)
{
  for(GList *l = H.edit.dev.iop; l; l = g_list_next(l))
  {
    dt_iop_module_t *m = l->data;
    gchar *k = _module_key(m);
    const gboolean match = !g_strcmp0(k, key);
    g_free(k);
    if(match) return m;
  }
  return NULL;
}

static dt_introspection_field_t *_find_field(dt_iop_module_t *m, const char *name)
{
  if(!m->so->have_introspection) return NULL;
  for(dt_introspection_field_t *f = m->so->get_introspection_linear();
      f && f->header.type != DT_INTROSPECTION_TYPE_NONE; f++)
  {
    if(!g_strcmp0(f->header.name, name)) return f;
  }
  return NULL;
}

static gboolean _in_history(const dt_iop_module_t *m)
{
  GList *h = H.edit.dev.history;
  for(int k = 0; k < H.edit.dev.history_end && h; k++, h = g_list_next(h))
  {
    const dt_dev_history_item_t *item = h->data;
    if(item->module == m) return TRUE;
  }
  return FALSE;
}

// ------------------------------------------------- introspection to JSON

static void _number(JsonBuilder *b, const char *key, double v)
{
  json_builder_set_member_name(b, key);
  // darktable uses +-G_MAXFLOAT for "no limit"; send null instead
  if(fabs(v) >= G_MAXFLOAT / 2) json_builder_add_null_value(b);
  else json_builder_add_double_value(b, v);
}

static void _field_header(JsonBuilder *b, const dt_introspection_field_t *f, const char *kind)
{
  json_builder_begin_object(b);
  json_builder_set_member_name(b, "name");
  json_builder_add_string_value(b, f->header.name);
  json_builder_set_member_name(b, "label");
  const char *d = f->header.description;
  json_builder_add_string_value(b, d && *d ? d : f->header.field_name);
  json_builder_set_member_name(b, "described");
  json_builder_add_boolean_value(b, d && *d);
  json_builder_set_member_name(b, "kind");
  json_builder_add_string_value(b, kind);
}

// walk the params struct; emits controls the app can generate, counts the rest
static void _walk(JsonBuilder *b, dt_introspection_field_t *f, const char *params, int *skipped)
{
  const char *p = params + f->header.offset;
  switch(f->header.type)
  {
    case DT_INTROSPECTION_TYPE_STRUCT:
      for(size_t i = 0; i < f->Struct.entries; i++) _walk(b, f->Struct.fields[i], params, skipped);
      break;
    case DT_INTROSPECTION_TYPE_FLOAT:
      _field_header(b, f, "float");
      _number(b, "min", f->Float.Min);
      _number(b, "max", f->Float.Max);
      _number(b, "default", f->Float.Default);
      _number(b, "value", *(const float *)p);
      json_builder_end_object(b);
      break;
    case DT_INTROSPECTION_TYPE_INT:
      _field_header(b, f, "int");
      _number(b, "min", f->Int.Min == G_MININT ? -G_MAXFLOAT : f->Int.Min);
      _number(b, "max", f->Int.Max == G_MAXINT ? G_MAXFLOAT : f->Int.Max);
      _number(b, "default", f->Int.Default);
      _number(b, "value", *(const int *)p);
      json_builder_end_object(b);
      break;
    case DT_INTROSPECTION_TYPE_BOOL:
      _field_header(b, f, "bool");
      json_builder_set_member_name(b, "default");
      json_builder_add_boolean_value(b, f->Bool.Default);
      json_builder_set_member_name(b, "value");
      json_builder_add_boolean_value(b, *(const gboolean *)p);
      json_builder_end_object(b);
      break;
    case DT_INTROSPECTION_TYPE_ENUM:
      _field_header(b, f, "enum");
      json_builder_set_member_name(b, "default");
      json_builder_add_int_value(b, f->Enum.Default);
      json_builder_set_member_name(b, "value");
      json_builder_add_int_value(b, *(const int *)p);
      json_builder_set_member_name(b, "options");
      json_builder_begin_array(b);
      for(size_t i = 0; i < f->Enum.entries; i++)
      {
        const dt_introspection_type_enum_tuple_t *t = &f->Enum.values[i];
        json_builder_begin_object(b);
        json_builder_set_member_name(b, "value");
        json_builder_add_int_value(b, t->value);
        json_builder_set_member_name(b, "label");
        json_builder_add_string_value(b, t->description && *t->description ? t->description : t->name);
        json_builder_end_object(b);
      }
      json_builder_end_array(b);
      json_builder_end_object(b);
      break;
    default:
      // arrays (curves, masks, nodes), unions and odd scalar types need hand-built editors
      (*skipped)++;
      break;
  }
}

static void _add_modules(JsonBuilder *b)
{
  json_builder_set_member_name(b, "modules");
  json_builder_begin_array(b);
  // darkroom lists the end of the pipe first; do the same
  for(GList *l = g_list_last(H.edit.dev.iop); l; l = g_list_previous(l))
  {
    dt_iop_module_t *m = l->data;
    if(dt_iop_is_hidden(m) || !m->so->have_introspection) continue;

    json_builder_begin_object(b);
    gchar *key = _module_key(m);
    json_builder_set_member_name(b, "key");
    json_builder_add_string_value(b, key);
    g_free(key);
    json_builder_set_member_name(b, "op");
    json_builder_add_string_value(b, m->op);
    json_builder_set_member_name(b, "name");
    json_builder_add_string_value(b, dt_iop_get_localized_name(m->op));
    json_builder_set_member_name(b, "instanceName");
    json_builder_add_string_value(b, m->multi_name);
    json_builder_set_member_name(b, "enabled");
    json_builder_add_boolean_value(b, m->enabled);
    // darktable hides deprecated modules (old filmic, basic adjustments...) unless in use
    json_builder_set_member_name(b, "deprecated");
    json_builder_add_boolean_value(b, (m->so->flags() & IOP_FLAGS_DEPRECATED) != 0);
    json_builder_set_member_name(b, "canDisable");
    json_builder_add_boolean_value(b, !m->hide_enable_button);
    // darktable's own sign that a module can't work on this image (demosaic,
    // raw prepare, raw denoise and so on, on a non-raw or a monochrome raw):
    // off by default with its on/off control removed
    json_builder_set_member_name(b, "applicable");
    json_builder_add_boolean_value(b, !(m->hide_enable_button && !m->default_enabled && !m->enabled));
    json_builder_set_member_name(b, "inHistory");
    json_builder_add_boolean_value(b, _in_history(m));
    json_builder_set_member_name(b, "order");
    json_builder_add_int_value(b, m->iop_order);

    int skipped = 0;
    json_builder_set_member_name(b, "fields");
    json_builder_begin_array(b);
    _walk(b, m->so->get_introspection()->field, (const char *)m->params, &skipped);
    json_builder_end_array(b);
    json_builder_set_member_name(b, "unsupportedFields");
    json_builder_add_int_value(b, skipped);
    // text settings (char arrays, such as the lens module's camera and lens),
    // which the app shows but doesn't edit
    json_builder_set_member_name(b, "text");
    json_builder_begin_object(b);
    for(dt_introspection_field_t *f = m->so->get_introspection_linear(); f && f->header.type != DT_INTROSPECTION_TYPE_NONE; f++)
    {
      if(f->header.type != DT_INTROSPECTION_TYPE_ARRAY || f->Array.type != DT_INTROSPECTION_TYPE_CHAR) continue;
      json_builder_set_member_name(b, f->header.field_name);
      json_builder_add_string_value(b, (const char *)m->params + f->header.offset);
    }
    json_builder_end_object(b);
    json_builder_end_object(b);
  }
  json_builder_end_array(b);
}

// ------------------------------------------------------------- commands

static void _close_view(view_t *v)
{
  if(!v->loaded) return;
  dt_dev_pixelpipe_cleanup(&v->pipe);
  dt_mipmap_cache_release(&v->buf);
  dt_dev_cleanup(&v->dev);
  v->loaded = FALSE;
}

static void _close_image(void)
{
  _close_view(&H.edit);
  _close_view(&H.before);
}

// the export profile chosen in colorout; the app uses it to show HDR output
// the way PQ or HLG export will encode it
static int _output_profile_type(const view_t *v)
{
  for(GList *l = v->dev.iop; l; l = g_list_next(l))
  {
    dt_iop_module_t *m = l->data;
    if(strcmp(m->op, "colorout") || m->multi_priority) continue;
    dt_introspection_field_t *f = _find_field(m, "type");
    if(f) return *(const int *)((const char *)m->params + f->header.offset);
  }
  return DT_COLORSPACE_SRGB;
}

// The darkroom (FULL) pipe ignores pipe->icc_type and renders to darktable's
// global display profile, so that's what we switch between modes. The helper
// is darktable's only client in this process, so the global is ours.
static void _set_output_mode(const gboolean hdr)
{
  darktable.color_profiles->display_type = hdr ? DT_COLORSPACE_LIN_REC2020 : DT_COLORSPACE_SRGB;
  darktable.color_profiles->display_filename[0] = '\0';
  darktable.color_profiles->display_intent = DT_INTENT_PERCEPTUAL;
  H.hdr = hdr;
}

// builds develop state and a pipe for an image already in the library,
// from the history currently in the library
static const char *_load_view(view_t *v, const dt_imgid_t imgid)
{
  _close_view(v);

  dt_dev_init(&v->dev, FALSE);
  dt_dev_load_image(&v->dev, imgid);
  // without a GUI, loading leaves module params at defaults; apply the
  // history so params and on/off states match the edit
  dt_dev_pop_history_items_ext(&v->dev, v->dev.history_end);

  dt_mipmap_cache_get(&v->buf, imgid, DT_MIPMAP_FULL, DT_MIPMAP_BLOCKING, 'r');
  if(!v->buf.buf || !v->buf.width || !v->buf.height)
  {
    dt_dev_cleanup(&v->dev);
    return "darktable could not decode this file";
  }

  // a long-lived pipe with a real cache: after a slider move, only the
  // modules from the changed one onwards are recomputed. The darkroom
  // (FULL) type takes darktable's interactive fast paths, about 10x quicker
  // per change than an export pipe; final exports should use an export pipe.
  dt_dev_pixelpipe_init_cached(&v->pipe, 0, 64, 8);
  v->pipe.type = DT_DEV_PIXELPIPE_FULL;
  v->pipe.input_hint = NULL;
  v->pipe.levels = IMAGEIO_RGB | IMAGEIO_INT8;

  dt_ioppr_resync_modules_order(&v->dev);
  _set_output_mode(H.hdr);
  dt_dev_pixelpipe_set_input(&v->pipe, &v->dev, (float *)v->buf.buf,
                             v->buf.width, v->buf.height, v->buf.iscale);
  dt_dev_pixelpipe_create_nodes(&v->pipe, &v->dev);
  dt_dev_pixelpipe_synch_all(&v->pipe, &v->dev);
  dt_dev_pixelpipe_get_dimensions(&v->pipe, &v->dev, v->pipe.iwidth, v->pipe.iheight,
                                  &v->pipe.processed_width, &v->pipe.processed_height);
  v->loaded = TRUE;
  v->dirty = FALSE;
  return NULL;
}

// (re)loads the edit; the before view is left alone
static const char *_load(const dt_imgid_t imgid)
{
  H.imgid = imgid;
  H.histogram_module = NULL;
  return _load_view(&H.edit, imgid);
}

static void _sync_hdr_white(void);

static void _cmd_open(JsonObject *o)
{
  const char *path = json_object_get_string_member_with_default(o, "path", NULL);
  if(!path || !g_file_test(path, G_FILE_TEST_IS_REGULAR)) return _error("file not found");
  _close_image();

  // the library is in memory, so the XMP sidecar is the only saved state:
  // an existing sidecar (from this app or from darktable) is read on import
  gchar *xmp = g_strconcat(path, ".xmp", NULL);
  const gboolean had_sidecar = g_file_test(xmp, G_FILE_TEST_IS_REGULAR);
  g_free(xmp);

  gchar *dir = g_path_get_dirname(path);
  dt_film_t film;
  const dt_filmid_t filmid = dt_film_new(&film, dir);
  g_free(dir);
  const dt_imgid_t imgid = dt_image_import(filmid, path, TRUE, FALSE);
  if(!dt_is_valid_imgid(imgid)) return _error("darktable could not import this file");

  // The sidecar is the edit. darktable only reads it the first time a file
  // is imported, so a file opened again this session (a decode whose sidecar
  // the app has replaced or removed) would come back with the history it had
  // then: read it again, or clear the history when there's none.
  if(had_sidecar)
  {
    gchar *xmp_path = g_strconcat(path, ".xmp", NULL);
    dt_image_t *img = dt_image_cache_get(imgid, 'w');
    if(img)
    {
      dt_exif_xmp_read(img, xmp_path, 1);
      dt_image_cache_write_release(img, DT_IMAGE_CACHE_RELAXED);
    }
    g_free(xmp_path);
  }
  else
    dt_history_delete_on_image_ext(imgid, FALSE, TRUE);

  const char *err = _load(imgid);
  if(!err) err = _load_view(&H.before, imgid);
  if(err) return _error(err);
  H.hdr_source = json_object_get_boolean_member_with_default(o, "hdrSource", FALSE);
  if(H.hdr_source) _sync_hdr_white();

  const dt_image_t *img = &H.edit.dev.image_storage;
  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "width");
  json_builder_add_int_value(b, H.edit.pipe.processed_width);
  json_builder_set_member_name(b, "height");
  json_builder_add_int_value(b, H.edit.pipe.processed_height);
  json_builder_set_member_name(b, "camera");
  json_builder_add_string_value(b, img->camera_makermodel);
  json_builder_set_member_name(b, "maker");
  json_builder_add_string_value(b, img->camera_maker);
  json_builder_set_member_name(b, "model");
  json_builder_add_string_value(b, img->camera_model);
  json_builder_set_member_name(b, "alias");
  json_builder_add_string_value(b, img->camera_alias);
  // sensor layout decides which demosaic methods apply, as in darktable's interface
  json_builder_set_member_name(b, "sensor");
  json_builder_add_string_value(b, dt_image_monochrome_flags(img) ? "monochrome"
                                   : img->buf_dsc.filters == 9u ? "xtrans"
                                   : img->buf_dsc.filters ? "bayer" : "linear");
  json_builder_set_member_name(b, "hadSidecar");
  json_builder_add_boolean_value(b, had_sidecar);
  _add_modules(b);
  _ok_done(b);
}

static gboolean _ensure_frame(size_t bytes)
{
  if(bytes <= H.frame_cap) return TRUE;
  if(H.frame_map) munmap(H.frame_map, H.frame_cap);
  H.frame_map = NULL;
  if(ftruncate(H.frame_fd, bytes)) return FALSE;
  H.frame_map = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, H.frame_fd, 0);
  if(H.frame_map == MAP_FAILED) { H.frame_map = NULL; return FALSE; }
  H.frame_cap = bytes;
  return TRUE;
}

static dt_dev_pixelpipe_iop_t *_edit_piece(const dt_iop_module_t *m)
{
  for(GList *l = H.edit.pipe.nodes; l; l = g_list_next(l))
    if(((dt_dev_pixelpipe_iop_t *)l->data)->module == m) return l->data;
  return NULL;
}

// Commits overridden params to the pipe's nodes for one render. Several
// overrides of one module are combined into one set of params.
static void _apply_overrides(view_t *v, JsonArray *ov)
{
  typedef struct { dt_iop_module_t *m; dt_dev_pixelpipe_iop_t *piece; void *params; gboolean enable; } pending_t;
  pending_t pending[32];
  int n = 0;
  for(guint i = 0; i < json_array_get_length(ov); i++)
  {
    JsonObject *e = json_array_get_object_element(ov, i);
    dt_iop_module_t *m = _find_module(json_object_get_string_member_with_default(e, "module", ""));
    const char *field = json_object_get_string_member_with_default(e, "field", "");
    dt_introspection_field_t *f = m && *field ? _find_field(m, field) : NULL;
    // no field: only "enable", running the module as it is (for its histogram)
    if(!m || (*field && (!f || (f->header.type != DT_INTROSPECTION_TYPE_FLOAT && f->header.type != DT_INTROSPECTION_TYPE_INT
                                 && f->header.type != DT_INTROSPECTION_TYPE_ENUM && f->header.type != DT_INTROSPECTION_TYPE_BOOL))))
      continue;
    int k = 0;
    while(k < n && pending[k].m != m) k++;
    if(k == n)
    {
      dt_dev_pixelpipe_iop_t *piece = NULL;
      for(GList *l = v->pipe.nodes; l && !piece; l = g_list_next(l))
        if(((dt_dev_pixelpipe_iop_t *)l->data)->module == m) piece = l->data;
      if(!piece || n == G_N_ELEMENTS(pending)) continue;
      void *params = g_malloc(m->params_size);
      memcpy(params, m->params, m->params_size);
      pending[n++] = (pending_t){ m, piece, params, m->enabled };
    }
    if(f)
    {
      char *at = (char *)pending[k].params + f->header.offset;
      const double value = json_object_get_double_member_with_default(e, "value", 0);
      switch(f->header.type)
      {
        case DT_INTROSPECTION_TYPE_FLOAT: *(float *)at = CLAMP((float)value, f->Float.Min, f->Float.Max); break;
        case DT_INTROSPECTION_TYPE_INT: *(int *)at = CLAMP((int)lround(value), f->Int.Min, f->Int.Max); break;
        // a choice (such as flip's orientation) or an on/off setting
        case DT_INTROSPECTION_TYPE_ENUM: *(int *)at = (int)lround(value); break;
        case DT_INTROSPECTION_TYPE_BOOL: *(gboolean *)at = value != 0; break;
        default: break;
      }
    }
    pending[k].enable |= json_object_get_boolean_member_with_default(e, "enable", FALSE);
    // "disable": runs the render without the module (a look's previews start from the photo without it)
    if(json_object_get_boolean_member_with_default(e, "disable", FALSE)) pending[k].enable = FALSE;
  }
  for(int k = 0; k < n; k++)
  {
    // the cache key hashes module->params, not the params committed, so point
    // the module at the overridden ones while committing; otherwise the pipe
    // serves the edit's cached output for the overridden modules
    dt_iop_module_t *m = pending[k].m;
    void *own = m->params;
    m->params = pending[k].params;
    pending[k].piece->enabled = pending[k].enable;
    dt_iop_commit_params(m, pending[k].params, m->blend_params, &v->pipe, pending[k].piece);
    m->params = own;
    g_free(pending[k].params);
  }
  v->overridden = n > 0;
  // an override can change the output size (the crop opened out while cropping)
  if(n > 0)
    dt_dev_pixelpipe_get_dimensions(&v->pipe, &v->dev, v->pipe.iwidth, v->pipe.iheight,
                                    &v->pipe.processed_width, &v->pipe.processed_height);
}

static void _cmd_render(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  const double t0 = dt_get_wtime();
  const int max = json_object_get_int_member_with_default(o, "max", 1600);
  const gboolean hdr = json_object_get_boolean_member_with_default(o, "hdr", FALSE);
  // "before" renders the photo as it was when opened, for comparison
  const gboolean before = json_object_get_boolean_member_with_default(o, "before", FALSE);
  view_t *v = before ? &H.before : &H.edit;
  if(!v->loaded) return _error("no image open");

  // "overrides" renders the current edit with some settings changed, without
  // touching the edit: [{"module":"sigmoid:0","field":"display_white_target","value":100}],
  // optionally with "enable": true to switch a module on for this render.
  // They're committed straight to the edit pipe's nodes after it syncs, so the
  // pipe cache (keyed by params) still serves everything before them.
  JsonArray *ov = json_object_has_member(o, "overrides") ? json_object_get_array_member(o, "overrides") : NULL;
  if(ov && before) return _error("overrides apply to the edit only");

  if(hdr != H.hdr)
  {
    // the display profile isn't in the cache hashes, and nor is gamma being
    // skipped, so drop the cached output of colorout and everything after it.
    // Everything before is the same in both modes and stays cached, so a
    // switch costs those last modules rather than a full render.
    _set_output_mode(hdr);
    view_t *views[] = { &H.edit, &H.before };
    for(size_t i = 0; i < G_N_ELEMENTS(views); i++)
    {
      view_t *each = views[i];
      if(!each->loaded) continue;
      int32_t order = 0;
      for(GList *l = each->dev.iop; l && !order; l = g_list_next(l))
      {
        dt_iop_module_t *m = l->data;
        if(!g_strcmp0(m->op, "colorout")) order = m->iop_order;
      }
      dt_dev_pixelpipe_cache_invalidate_later(&each->pipe, order, "output mode: ");
      each->dirty = TRUE;
    }
  }

  if(v->dirty || v->overridden || ov)
  {
    v->pipe.changed |= DT_DEV_PIPE_SYNCH;
    dt_dev_pixelpipe_change(&v->pipe, &v->dev);
    v->dirty = FALSE;
    v->overridden = FALSE;
  }
  if(ov) _apply_overrides(v, ov);
  if(v == &H.edit && H.histogram_module)
  {
    dt_dev_pixelpipe_iop_t *piece = _edit_piece(H.histogram_module);
    if(piece) piece->request_histogram = DT_REQUEST_ON;
    H.histogram_module->histogram_middle_grey = TRUE;
  }

  const int pw = v->pipe.processed_width, ph = v->pipe.processed_height;
  // Either the whole image fitted within max pixels, or, when "scale" is
  // given, a crop of the image at that scale (1 = full resolution): the
  // region "x", "y", "w", "h" in pixels of the scaled image, clamped to it.
  // darktable's darkroom zooms the same way, and at 100% it runs the full
  // demosaic rather than the fast preview one.
  const double zoom = json_object_get_double_member_with_default(o, "scale", 0.0);
  float scale;
  int ox = 0, oy = 0, w, h;
  if(zoom > 0.0)
  {
    scale = fminf((float)zoom, 4.0f);
    const int sw = floorf(scale * pw), sh = floorf(scale * ph);
    w = MIN((int)json_object_get_int_member_with_default(o, "w", 1600), sw);
    h = MIN((int)json_object_get_int_member_with_default(o, "h", 1200), sh);
    ox = CLAMP((int)json_object_get_int_member_with_default(o, "x", 0), 0, sw - w);
    oy = CLAMP((int)json_object_get_int_member_with_default(o, "y", 0), 0, sh - h);
  }
  else
  {
    scale = fminf(1.0f, fminf((float)max / pw, (float)max / ph));
    w = floorf(scale * pw);
    h = floorf(scale * ph);
  }

  // process returns TRUE if the pipe changed underneath it; retry a few times.
  // HDR skips the gamma module, which would quantise to 8 bits and clip at 1.0
  int tries = 0;
  if(hdr)
    while(dt_dev_pixelpipe_process_no_gamma(&v->pipe, &v->dev, ox, oy, w, h, scale) && ++tries < 3);
  else
    while(dt_dev_pixelpipe_process(&v->pipe, &v->dev, ox, oy, w, h, scale, DT_DEVICE_NONE) && ++tries < 3);

  if(!v->pipe.backbuf) return _error("render produced no output");
  // trust the size darktable produced over the one we asked for, so a module
  // that changes the output size can't shear the frame
  if(v->pipe.backbuf_width != w || v->pipe.backbuf_height != h)
    return _error("render came back at an unexpected size");
  // with Engine/patches/0001, backbuf holds float RGBA when gamma is skipped.
  // (In SDR the gamma module writes BGRA8 into a buffer still described as
  // float, so only the first w*h*4 bytes are meaningful.)
  const size_t bpp = hdr ? 4 * sizeof(float) : 4;
  const size_t bytes = (size_t)w * h * bpp;
  if(v->pipe.backbuf_bpp < bpp) return _error("unexpected output format from the pipe");
  if(!_ensure_frame(bytes)) return _error("could not map the frame file");
  memcpy(H.frame_map, v->pipe.backbuf, bytes);

  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "width");
  json_builder_add_int_value(b, w);
  json_builder_set_member_name(b, "height");
  json_builder_add_int_value(b, h);
  json_builder_set_member_name(b, "x");
  json_builder_add_int_value(b, ox);
  json_builder_set_member_name(b, "y");
  json_builder_add_int_value(b, oy);
  json_builder_set_member_name(b, "scale");
  json_builder_add_double_value(b, scale);
  json_builder_set_member_name(b, "hdr");
  json_builder_add_boolean_value(b, hdr);
  json_builder_set_member_name(b, "outputProfile");
  json_builder_add_int_value(b, _output_profile_type(v));
  // the full-size output, which crop and rotation change
  json_builder_set_member_name(b, "processedWidth");
  json_builder_add_int_value(b, pw);
  json_builder_set_member_name(b, "processedHeight");
  json_builder_add_int_value(b, ph);
  // the size reaching rotate and perspective, for working out its crop margins
  for(GList *l = v->pipe.nodes; l; l = g_list_next(l))
  {
    dt_dev_pixelpipe_iop_t *piece = l->data;
    if(g_strcmp0(piece->module->op, "ashift")) continue;
    json_builder_set_member_name(b, "rotateInWidth");
    json_builder_add_int_value(b, piece->buf_in.width);
    json_builder_set_member_name(b, "rotateInHeight");
    json_builder_add_int_value(b, piece->buf_in.height);
    break;
  }
  json_builder_set_member_name(b, "ms");
  json_builder_add_int_value(b, (gint64)((dt_get_wtime() - t0) * 1000));
  _ok_done(b);
}

static void _commit(dt_iop_module_t *m, const gboolean enable)
{
  // modules with automatic defaults (lens correction) ignore their params
  // until has_been_set, which darktable's interface sets on the first change;
  // without it, choosing a lens or changing a correction did nothing
  dt_introspection_field_t *set = _find_field(m, "has_been_set");
  if(set && set->header.type == DT_INTROSPECTION_TYPE_BOOL)
    *(gboolean *)((char *)m->params + set->header.offset) = TRUE;
  // keep this module's input cached (patch 0003), as darktable's darkroom does
  // for the module being edited, so the next change reruns the pipe from here
  H.edit.pipe.input_hint = m;
  // no_image=TRUE: we drive our own pipe, so skip darktable's GUI redraw path
  dt_dev_add_history_item_ext(&H.edit.dev, m, enable, TRUE);
  H.edit.dirty = TRUE;
  // a new output profile, or a tone mapper on or off, changes where an HDR source's white belongs
  if(H.hdr_source && (!strcmp(m->op, "colorout") || !strcmp(m->op, "sigmoid") || !strcmp(m->op, "filmicrgb")
                      || !strcmp(m->op, "agx") || !strcmp(m->op, "basecurve")))
    _sync_hdr_white();
}

static void _cmd_set(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *m = _find_module(json_object_get_string_member_with_default(o, "module", ""));
  if(!m) return _error("unknown module");
  dt_introspection_field_t *f = _find_field(m, json_object_get_string_member_with_default(o, "field", ""));
  if(!f) return _error("unknown field");
  JsonNode *v = json_object_get_member(o, "value");
  if(!v) return _error("missing value");

  char *p = (char *)m->params + f->header.offset;
  switch(f->header.type)
  {
    case DT_INTROSPECTION_TYPE_FLOAT:
      *(float *)p = CLAMP((float)json_node_get_double(v), f->Float.Min, f->Float.Max);
      break;
    case DT_INTROSPECTION_TYPE_INT:
      *(int *)p = CLAMP((int)json_node_get_int(v), f->Int.Min, f->Int.Max);
      break;
    case DT_INTROSPECTION_TYPE_BOOL:
      *(gboolean *)p = json_node_get_boolean(v);
      break;
    case DT_INTROSPECTION_TYPE_ENUM:
      *(int *)p = (int)json_node_get_int(v);
      break;
    default:
      return _error("field type not editable");
  }
  _commit(m, TRUE);
  _ok_done(_ok());
}

// ------------------------------------------------------- automatic exposure

// darktable's automatic exposure (exposure's "deflicker" mode) only runs on
// 16-bit mosaic raws; on anything else (monochrome and other non-mosaic raws,
// linear DNGs, JPEGs, TIFFs) it silently does nothing. This works out the same
// value for any input: the given percentile of the input data, in EV below
// white, is brought to the target level, as darktable does. Raws use their
// black and white levels; other images aim their percentile a little below
// middle grey, after undoing the sRGB curve of display-referred files.
static float _float_param(dt_iop_module_t *m, const char *name, float fallback)
{
  dt_introspection_field_t *f = _find_field(m, name);
  return f && f->header.type == DT_INTROSPECTION_TYPE_FLOAT ? *(float *)((char *)m->params + f->header.offset) : fallback;
}

static gboolean _bool_param(dt_iop_module_t *m, const char *name)
{
  dt_introspection_field_t *f = _find_field(m, name);
  return f && f->header.type == DT_INTROSPECTION_TYPE_BOOL && *(gboolean *)((char *)m->params + f->header.offset);
}

static gboolean _auto_exposure_value(dt_iop_module_t *m, gboolean standard, float *exposure)
{
  const dt_image_t *img = &H.edit.dev.image_storage;
  const dt_mipmap_buffer_t *buf = &H.edit.buf;
  if(!buf->buf || buf->width <= 0 || buf->height <= 0) return FALSE;
  const int ch = img->buf_dsc.channels;
  const dt_iop_buffer_type_t type = img->buf_dsc.datatype;
  const gboolean raw = dt_image_is_raw(img);
  const gboolean srgb = !raw && dt_image_is_ldr(img);
  // standard: darktable's default rule rather than the module's own settings
  const float percentile = standard ? 50.0f : _float_param(m, "deflicker_percentile", 50.0f);
  // a processed image was exposed by the camera already, and mostly dark scenes
  // shouldn't be pushed to middle grey: its middle tone aims a little lower
  const float target = !raw ? -3.0f : standard ? -4.0f : _float_param(m, "deflicker_target_level", -4.0f);
  const uint32_t black = raw ? img->raw_black_level : 0;
  const uint32_t white = raw ? img->raw_white_point : 65535;
  if(white <= black) return FALSE;

  // a histogram of 16-bit values over a sample of the photo; an odd step
  // keeps every site of a 2 × 2 mosaic in the sample
  uint32_t *hist = calloc(65536, sizeof(uint32_t));
  if(!hist) return FALSE;
  const int x0 = raw ? MAX(img->crop_x, 0) : 0, y0 = raw ? MAX(img->crop_y, 0) : 0;
  const int x1 = buf->width - (raw ? MAX(img->crop_right, 0) : 0), y1 = buf->height - (raw ? MAX(img->crop_bottom, 0) : 0);
  const int step = MAX(1, (int)(sqrtf((float)buf->width * buf->height / 2.0e6f)) | 1);
  const int colours = ch == 1 ? 1 : 3;
  uint64_t n = 0;
  for(int y = y0; y < y1; y += step)
    for(int x = x0; x < x1; x += step)
      for(int c = 0; c < colours; c++)
      {
        const size_t i = ((size_t)y * buf->width + x) * ch + c;
        float v;
        if(type == TYPE_UINT16) v = ((const uint16_t *)buf->buf)[i] / 65535.0f;
        else if(type == TYPE_FLOAT) v = ((const float *)buf->buf)[i];
        else { free(hist); return FALSE; }
        if(srgb) v = v <= 0.04045f ? v / 12.92f : powf((v + 0.055f) / 1.055f, 2.4f);
        hist[(int)CLAMP(v * 65535.0f + 0.5f, 0.0f, 65535.0f)]++;
        n++;
      }
  if(n == 0) { free(hist); return FALSE; }
  const uint64_t thr = (uint64_t)((double)n * CLAMP(percentile, 0.0f, 100.0f) / 100.0);
  uint64_t acc = 0;
  uint32_t value = 0;
  for(uint32_t i = 0; i < 65536; i++)
  {
    acc += hist[i];
    if(acc >= thr) { value = i; break; }
  }
  free(hist);
  // _raw_to_ev in iop/exposure.c
  const double ev = -log2((double)(white - black)) + log2((double)MAX((int64_t)value - (int64_t)black, 1));
  float correction = target - (float)ev;
  // as a manual value: the module takes off the camera's exposure bias and adds
  // its highlight-preservation bias when those options are on
  if(_bool_param(m, "compensate_exposure_bias") && img->exif_exposure_bias != DT_EXIF_TAG_UNINITIALIZED)
    correction += CLAMP(img->exif_exposure_bias, -5.0f, 5.0f);
  if(_bool_param(m, "compensate_hilite_pres") && img->exif_highlight_preservation > 0.0f
     && img->exif_highlight_preservation != DT_EXIF_TAG_UNINITIALIZED)
    correction -= CLAMP(img->exif_highlight_preservation, -1.0f, 4.0f);
  *exposure = CLAMP(correction, -18.0f, 18.0f);
  return TRUE;
}

// {"cmd":"auto_exposure","module":"exposure:0","standard":true} -> {"exposure": 1.23},
// the manual exposure darktable's automatic mode would apply, with its default
// percentile and target if "standard", else the module's own. Changes nothing.
static void _cmd_auto_exposure(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *m = _find_module(json_object_get_string_member_with_default(o, "module", "exposure:0"));
  if(!m || strcmp(m->op, "exposure")) return _error("not an exposure module");
  float exposure = 0.0f;
  if(!_auto_exposure_value(m, json_object_get_boolean_member_with_default(o, "standard", TRUE), &exposure)) return _error("couldn't measure this photo");
  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "exposure");
  json_builder_add_double_value(b, exposure);
  _ok_done(b);
}

// several settings in one request: [{"module":..,"field":..,"value":..}, ...]
// One round trip for a slider that drives many fields (tone equalizer zones).
static void _cmd_set_many(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  JsonArray *items = json_object_has_member(o, "items") ? json_object_get_array_member(o, "items") : NULL;
  if(!items) return _error("missing items");
  for(guint i = 0; i < json_array_get_length(items); i++)
  {
    JsonObject *e = json_array_get_object_element(items, i);
    dt_iop_module_t *m = _find_module(json_object_get_string_member_with_default(e, "module", ""));
    dt_introspection_field_t *f = m ? _find_field(m, json_object_get_string_member_with_default(e, "field", "")) : NULL;
    JsonNode *v = json_object_get_member(e, "value");
    if(!f || !v) continue;
    char *p = (char *)m->params + f->header.offset;
    switch(f->header.type)
    {
      case DT_INTROSPECTION_TYPE_FLOAT: *(float *)p = CLAMP((float)json_node_get_double(v), f->Float.Min, f->Float.Max); break;
      case DT_INTROSPECTION_TYPE_INT: *(int *)p = CLAMP((int)json_node_get_int(v), f->Int.Min, f->Int.Max); break;
      case DT_INTROSPECTION_TYPE_BOOL: *(gboolean *)p = json_node_get_boolean(v); break;
      case DT_INTROSPECTION_TYPE_ENUM: *(int *)p = (int)json_node_get_int(v); break;
      default: continue;
    }
    _commit(m, TRUE);
  }
  _ok_done(_ok());
}

static void _cmd_enable(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *m = _find_module(json_object_get_string_member_with_default(o, "module", ""));
  if(!m) return _error("unknown module");
  const gboolean on = json_object_get_boolean_member_with_default(o, "on", TRUE);
  m->enabled = on;
  _commit(m, on);
  _ok_done(_ok());
}

static void _cmd_reset(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *m = _find_module(json_object_get_string_member_with_default(o, "module", ""));
  if(!m) return _error("unknown module");
  memcpy(m->params, m->default_params, m->params_size);
  _commit(m, m->enabled);
  JsonBuilder *b = _ok();
  _add_modules(b);
  _ok_done(b);
}

static void _cmd_modules(void)
{
  if(!H.edit.loaded) return _error("no image open");
  JsonBuilder *b = _ok();
  _add_modules(b);
  _ok_done(b);
}

// A new instance of a module, placed right after it with default settings:
// {"cmd":"add_instance","module":"rgbcurve:0","name":"channels"} -> its key
// and the module list. As darktable's duplicate button does, without the
// GUI: the instance goes into the history (and so the sidecar, with its
// name), and the pipe's nodes are rebuilt to include it.
static void _cmd_add_instance(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *base = _find_module(json_object_get_string_member_with_default(o, "module", ""));
  if(!base) return _error("unknown module");
  if(base->flags() & IOP_FLAGS_ONE_INSTANCE) return _error("this module can only be used once");
  // the base must be in the history for the instance to be placed after it
  dt_dev_add_history_item_ext(&H.edit.dev, base, FALSE, TRUE);
  dt_iop_module_t *m = dt_dev_module_duplicate(&H.edit.dev, base);
  if(!m) return _error("couldn't add an instance");
  dt_iop_reload_defaults(m);
  const char *name = json_object_get_string_member_with_default(o, "name", "");
  if(*name)
  {
    g_strlcpy(m->multi_name, name, sizeof(m->multi_name));
    m->multi_name_hand_edited = TRUE;
  }
  else
  {
    // numbered, as darktable shows instances; reloading the defaults can
    // leave the name of an automatically applied workflow preset
    snprintf(m->multi_name, sizeof(m->multi_name), "%d", m->multi_priority);
    // marked as given, or darktable names it again from presets
    m->multi_name_hand_edited = TRUE;
  }
  // off until it's given settings
  dt_dev_add_history_item_ext(&H.edit.dev, m, FALSE, TRUE);
  m->enabled = FALSE;
  dt_dev_add_history_item_ext(&H.edit.dev, m, FALSE, TRUE);

  dt_dev_pixelpipe_cleanup_nodes(&H.edit.pipe);
  dt_dev_pixelpipe_create_nodes(&H.edit.pipe, &H.edit.dev);
  dt_dev_pixelpipe_synch_all(&H.edit.pipe, &H.edit.dev);
  dt_dev_pixelpipe_cache_flush(&H.edit.pipe);
  H.edit.dirty = TRUE;

  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "added");
  gchar *key = _module_key(m);
  json_builder_add_string_value(b, key);
  g_free(key);
  _add_modules(b);
  _ok_done(b);
}

// ------------------------------------------------------------ lens picker

// The Lensfun database darktable's lens module has already loaded. Its global
// data isn't in a header; this mirrors the start of dt_iop_lens_global_data_t
// in iop/lens.cc (eight OpenCL kernel ids, then the database).
typedef struct lens_global_head_t
{
  int kernels[8];
  lfDatabase *db;
} lens_global_head_t;

static const lfDatabase *_lensfun_db(dt_iop_module_t **lens_module)
{
  for(GList *l = H.edit.dev.iop; l; l = g_list_next(l))
  {
    dt_iop_module_t *m = l->data;
    if(strcmp(m->op, "lens")) continue;
    if(lens_module) *lens_module = m;
    const lens_global_head_t *gd = m->so ? (const lens_global_head_t *)m->so->data : NULL;
    return gd ? gd->db : NULL;
  }
  return NULL;
}

static const char *_param_text(dt_iop_module_t *m, const char *field)
{
  dt_introspection_field_t *f = _find_field(m, field);
  return f && f->header.type == DT_INTROSPECTION_TYPE_ARRAY ? (const char *)m->params + f->header.offset : "";
}

// {"cmd":"lens_cameras","query":"z 50"} -> Lensfun's cameras matching the
// query (loosely), for when the photo's camera isn't recognised
static void _cmd_lens_cameras(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  const lfDatabase *db = _lensfun_db(NULL);
  if(!db) return _error("Lensfun isn't available");
  const char *query = json_object_get_string_member_with_default(o, "query", "");
  dt_pthread_mutex_lock(&darktable.plugin_threadsafe);
  const lfCamera **cams = *query ? lf_db_find_cameras_ext(db, NULL, query, LF_SEARCH_LOOSE | LF_SEARCH_SORT_AND_UNIQUIFY)
                                 : (const lfCamera **)NULL;
  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "cameras");
  json_builder_begin_array(b);
  for(int i = 0; cams && cams[i] && i < 60; i++)
  {
    json_builder_begin_object(b);
    json_builder_set_member_name(b, "maker");
    json_builder_add_string_value(b, lf_mlstr_get(cams[i]->Maker));
    json_builder_set_member_name(b, "model");
    json_builder_add_string_value(b, lf_mlstr_get(cams[i]->Model));
    json_builder_set_member_name(b, "mount");
    json_builder_add_string_value(b, cams[i]->Mount ? cams[i]->Mount : "");
    json_builder_set_member_name(b, "crop");
    json_builder_add_double_value(b, cams[i]->CropFactor);
    json_builder_end_object(b);
  }
  json_builder_end_array(b);
  if(cams) lf_free(cams);
  dt_pthread_mutex_unlock(&darktable.plugin_threadsafe);
  _ok_done(b);
}

// {"cmd":"lens_lenses","query":"35mm"} -> Lensfun's lenses that fit the lens
// module's camera (all of them if the query is empty), best match first
static void _cmd_lens_lenses(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *lens = NULL;
  const lfDatabase *db = _lensfun_db(&lens);
  if(!db || !lens) return _error("Lensfun isn't available");
  const char *query = json_object_get_string_member_with_default(o, "query", "");
  const char *camera_name = _param_text(lens, "camera");
  dt_pthread_mutex_lock(&darktable.plugin_threadsafe);
  const lfCamera **cams = *camera_name ? lf_db_find_cameras_ext(db, NULL, camera_name, 0) : NULL;
  const lfCamera *camera = cams ? cams[0] : NULL;
  const lfLens **lenses = lf_db_find_lenses_hd(db, camera, NULL, *query ? query : NULL,
                                              LF_SEARCH_LOOSE | LF_SEARCH_SORT_AND_UNIQUIFY);
  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "camera");
  json_builder_add_string_value(b, camera ? lf_mlstr_get(camera->Model) : "");
  json_builder_set_member_name(b, "lenses");
  json_builder_begin_array(b);
  for(int i = 0; lenses && lenses[i] && i < 5000; i++)
  {
    json_builder_begin_object(b);
    json_builder_set_member_name(b, "maker");
    json_builder_add_string_value(b, lf_mlstr_get(lenses[i]->Maker));
    json_builder_set_member_name(b, "model");
    json_builder_add_string_value(b, lf_mlstr_get(lenses[i]->Model));
    json_builder_set_member_name(b, "minFocal");
    json_builder_add_double_value(b, lenses[i]->MinFocal);
    json_builder_set_member_name(b, "maxFocal");
    json_builder_add_double_value(b, lenses[i]->MaxFocal);
    json_builder_set_member_name(b, "aperture");
    json_builder_add_double_value(b, lenses[i]->MinAperture);
    json_builder_end_object(b);
  }
  json_builder_end_array(b);
  if(lenses) lf_free(lenses);
  if(cams) lf_free(cams);
  dt_pthread_mutex_unlock(&darktable.plugin_threadsafe);
  _ok_done(b);
}

// {"cmd":"set_text","module":"lens:0","field":"lens","value":"..."}: a text
// setting (a char array), such as the lens module's camera and lens
static void _cmd_set_text(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *m = _find_module(json_object_get_string_member_with_default(o, "module", ""));
  if(!m) return _error("unknown module");
  dt_introspection_field_t *f = _find_field(m, json_object_get_string_member_with_default(o, "field", ""));
  if(!f || f->header.type != DT_INTROSPECTION_TYPE_ARRAY || f->Array.type != DT_INTROSPECTION_TYPE_CHAR)
    return _error("not a text setting");
  g_strlcpy((char *)m->params + f->header.offset, json_object_get_string_member_with_default(o, "value", ""),
            f->Array.count);
  _commit(m, TRUE);
  // the pipe cache keys each module on its committed data, which for lens
  // correction holds a pointer to the Lensfun lens rather than the lens, so a
  // new lens can look unchanged; run the module and what follows it again
  dt_dev_pixelpipe_cache_invalidate_later(&H.edit.pipe, m->iop_order, "text setting: ");
  _ok_done(_ok());
}

// ------------------------------------------------------ local adjustments

// A local adjustment is a module instance with one drawn shape as its mask: a
// linear gradient or an ellipse (radial). Shapes live in darktable's input
// coordinates (before lens correction, perspective, crop and flip), so the
// app talks in the photo as processed (full-size output pixels) and the
// engine moves points through the pipe's distortions both ways.

// Each node's buf_in is set when the pipe's dimensions are worked out, which
// happens at load; a module switched on since (lens correction, say) would
// transform with a zero size and return nonsense, so work them out afresh
static void _refresh_dimensions(void)
{
  dt_dev_pixelpipe_get_dimensions(&H.edit.pipe, &H.edit.dev, H.edit.pipe.iwidth, H.edit.pipe.iheight,
                                  &H.edit.pipe.processed_width, &H.edit.pipe.processed_height);
}

static gboolean _to_input(float *pts, const int n)
{
  _refresh_dimensions();
  return dt_dev_distort_backtransform_plus(&H.edit.dev, &H.edit.pipe, 0.0, DT_DEV_TRANSFORM_DIR_ALL, pts, n);
}

static gboolean _to_output(float *pts, const int n)
{
  _refresh_dimensions();
  return dt_dev_distort_transform_plus(&H.edit.dev, &H.edit.pipe, 0.0, DT_DEV_TRANSFORM_DIR_ALL, pts, n);
}

// the one shape in a module's mask group
static dt_masks_form_t *_local_shape(dt_iop_module_t *m)
{
  if(!m->blend_params) return NULL;
  dt_masks_form_t *grp = dt_masks_get_from_id(&H.edit.dev, m->blend_params->mask_id);
  if(!grp || !(grp->type & DT_MASKS_GROUP) || !grp->points) return NULL;
  const dt_masks_point_group_t *pt = grp->points->data;
  return dt_masks_get_from_id(&H.edit.dev, pt->formid);
}

static void _shape_changed(dt_iop_module_t *m)
{
  dt_dev_add_masks_history_item_ext(&H.edit.dev, m, TRUE, TRUE);
  _commit(m, TRUE);
  // the pipe cache's key doesn't cover the shape, so the module and what
  // follows it must run again
  dt_dev_pixelpipe_cache_invalidate_later(&H.edit.pipe, m->iop_order, "shape moved: ");
}

// {"cmd":"add_local","module":"exposure:0","shape":"gradient"|"ellipse","name":"Local 1"}
// -> the new instance's key and the module list. The shape starts across the
// middle (gradient) or centred (ellipse); set_shape places it.
static void _cmd_add_local(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *base = _find_module(json_object_get_string_member_with_default(o, "module", ""));
  if(!base) return _error("unknown module");
  if(!(base->flags() & IOP_FLAGS_SUPPORTS_BLENDING)) return _error("this module can't be masked");
  const char *shape = json_object_get_string_member_with_default(o, "shape", "gradient");
  const gboolean ellipse = !g_strcmp0(shape, "ellipse");
  const gboolean subject = !g_strcmp0(shape, "subject");
  // a subject's mask: 8-bit, one byte a pixel, over the photo as processed
  GList *traced = NULL, *signs = NULL;
  if(subject)
  {
    const char *path = json_object_get_string_member_with_default(o, "mask", "");
    const int mw = json_object_get_int_member_with_default(o, "maskWidth", 0);
    const int mh = json_object_get_int_member_with_default(o, "maskHeight", 0);
    gchar *bytes = NULL;
    gsize len = 0;
    if(mw <= 0 || mh <= 0 || !g_file_get_contents(path, &bytes, &len, NULL) || len < (gsize)mw * mh)
    {
      g_free(bytes);
      return _error("couldn't read the subject's mask");
    }
    // potrace's convention, as darktable's AI masks use it: below the threshold is inside
    float *inv = g_new(float, (size_t)mw * mh);
    for(size_t i = 0; i < (size_t)mw * mh; i++) inv[i] = 1.0f - (guchar)bytes[i] / 255.0f;
    g_free(bytes);
    // darktable's defaults for AI masks: specks under 10 pixels dropped, no extra smoothing
    traced = ras2forms(inv, mw, mh, NULL, 0.5f, 10, 0.0, &signs);
    g_free(inv);
    if(!traced) { g_list_free(signs); return _error("no subject found"); }
    // mask pixels to the photo as processed, then back through the pipe's
    // distortions to darktable's input, normalised
    _refresh_dimensions();
    const float sx = (float)H.edit.pipe.processed_width / mw, sy = (float)H.edit.pipe.processed_height / mh;
    const float iw = H.edit.pipe.iwidth, ih = H.edit.pipe.iheight;
    const float feather = CLAMP((float)json_object_get_double_member_with_default(o, "feather", 0.001), 0.0005f, 0.1f);
    for(GList *l = traced; l; l = g_list_next(l))
    {
      dt_masks_form_t *f = l->data;
      const int n = g_list_length(f->points);
      float *pts = g_new(float, 6 * n);
      int i = 0;
      for(GList *p = f->points; p; p = g_list_next(p))
      {
        const dt_masks_point_path_t *pt = p->data;
        pts[i++] = pt->corner[0] * sx; pts[i++] = pt->corner[1] * sy;
        pts[i++] = pt->ctrl1[0] * sx;  pts[i++] = pt->ctrl1[1] * sy;
        pts[i++] = pt->ctrl2[0] * sx;  pts[i++] = pt->ctrl2[1] * sy;
      }
      _to_input(pts, 3 * n);
      i = 0;
      for(GList *p = f->points; p; p = g_list_next(p))
      {
        dt_masks_point_path_t *pt = p->data;
        pt->corner[0] = pts[i++] / iw; pt->corner[1] = pts[i++] / ih;
        pt->ctrl1[0] = pts[i++] / iw;  pt->ctrl1[1] = pts[i++] / ih;
        pt->ctrl2[0] = pts[i++] / iw;  pt->ctrl2[1] = pts[i++] / ih;
        pt->border[0] = pt->border[1] = feather;
      }
      g_free(pts);
    }
  }

  dt_dev_add_history_item_ext(&H.edit.dev, base, FALSE, TRUE);
  dt_iop_module_t *m = dt_dev_module_duplicate(&H.edit.dev, base);
  if(!m)
  {
    g_list_free_full(traced, (GDestroyNotify)dt_masks_free_form);
    g_list_free(signs);
    return _error("couldn't add an instance");
  }
  dt_iop_reload_defaults(m);
  const char *name = json_object_get_string_member_with_default(o, "name", "");
  if(*name)
  {
    g_strlcpy(m->multi_name, name, sizeof(m->multi_name));
    m->multi_name_hand_edited = TRUE;
  }
  dt_dev_add_history_item_ext(&H.edit.dev, m, TRUE, TRUE);

  dt_masks_form_t *form = dt_masks_create(subject ? DT_MASKS_GROUP : ellipse ? DT_MASKS_ELLIPSE : DT_MASKS_GRADIENT);
  if(subject)
  {
    // as darktable's AI masks: the traced paths in a group of their own,
    // holes taken away, and that group the module's one shape
    snprintf(form->name, sizeof(form->name), "%s", name);
    GList *s = signs;
    int k = 1;
    for(GList *l = traced; l; l = g_list_next(l), s = s ? g_list_next(s) : NULL)
    {
      dt_masks_form_t *f = l->data;
      snprintf(f->name, sizeof(f->name), "%s path %d", name, k++);
      H.edit.dev.forms = g_list_append(H.edit.dev.forms, f);
      dt_masks_point_group_t *gp = dt_masks_group_add_form(form, f);
      if(gp && s && GPOINTER_TO_INT(s->data) == '-')
        gp->state = (gp->state & ~DT_MASKS_STATE_UNION) | DT_MASKS_STATE_DIFFERENCE;
    }
    g_list_free(traced);
    g_list_free(signs);
  }
  else if(ellipse)
  {
    dt_masks_point_ellipse_t *e = calloc(1, sizeof(dt_masks_point_ellipse_t));
    e->center[0] = e->center[1] = 0.5f;
    e->radius[0] = e->radius[1] = 0.25f;
    e->border = 0.5f;
    e->flags = DT_MASKS_ELLIPSE_PROPORTIONAL;
    form->points = g_list_append(form->points, e);
  }
  else
  {
    dt_masks_point_gradient_t *g = calloc(1, sizeof(dt_masks_point_gradient_t));
    g->anchor[0] = g->anchor[1] = 0.5f;
    g->compression = 0.3f;
    g->steepness = 0.0f;
    g->curvature = 0.0f;
    g->state = DT_MASKS_GRADIENT_STATE_SIGMOIDAL;
    form->points = g_list_append(form->points, g);
  }
  dt_masks_gui_form_save_creation(&H.edit.dev, m, form, NULL);
  m->blend_params->mask_mode = DEVELOP_MASK_ENABLED | DEVELOP_MASK_MASK;
  _commit(m, TRUE);

  dt_dev_pixelpipe_cleanup_nodes(&H.edit.pipe);
  dt_dev_pixelpipe_create_nodes(&H.edit.pipe, &H.edit.dev);
  dt_dev_pixelpipe_synch_all(&H.edit.pipe, &H.edit.dev);
  dt_dev_pixelpipe_cache_flush(&H.edit.pipe);
  H.edit.dirty = TRUE;

  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "added");
  gchar *key = _module_key(m);
  json_builder_add_string_value(b, key);
  g_free(key);
  _add_modules(b);
  _ok_done(b);
}

// Places a local adjustment's shape, in output pixels:
// gradient: {"anchor":[x,y],"toward":[x,y],"compression":0.3} - the line runs
//   through anchor, the adjustment fading in toward "toward" (perpendicular)
// ellipse: {"center":[x,y],"a":[x,y],"b":[x,y],"border":0.5} - a and b are
//   the ends of its two radii
static void _cmd_set_shape(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *m = _find_module(json_object_get_string_member_with_default(o, "module", ""));
  dt_masks_form_t *form = m ? _local_shape(m) : NULL;
  if(!form || !form->points) return _error("not a local adjustment");
  if(form->type & DT_MASKS_GROUP) return _error("a subject's outline can't be moved");
  const float iw = H.edit.pipe.iwidth, ih = H.edit.pipe.iheight;
  const float mind = fminf(iw, ih);
#define PT(name, i) (float)json_array_get_double_element(json_object_get_array_member(o, name), i)
  if(form->type & DT_MASKS_GRADIENT)
  {
    if(!json_object_has_member(o, "anchor") || !json_object_has_member(o, "toward")) return _error("missing points");
    float pts[4] = { PT("anchor", 0), PT("anchor", 1), PT("toward", 0), PT("toward", 1) };
    _to_input(pts, 2);
    dt_masks_point_gradient_t *g = form->points->data;
    g->anchor[0] = pts[0] / iw;
    g->anchor[1] = pts[1] / ih;
    // the line runs at v = -rotation (gradient.c); the adjustment's side is
    // at rotation - 90, so "toward" sets it
    const float side = atan2f(pts[3] - pts[1], pts[2] - pts[0]);
    g->rotation = -rad2degf(side) - 90.0f;
    if(json_object_has_member(o, "compression"))
      g->compression = CLAMP((float)json_object_get_double_member(o, "compression"), 0.001f, 1.0f);
  }
  else if(form->type & DT_MASKS_ELLIPSE)
  {
    if(!json_object_has_member(o, "center") || !json_object_has_member(o, "a") || !json_object_has_member(o, "b"))
      return _error("missing points");
    float pts[6] = { PT("center", 0), PT("center", 1), PT("a", 0), PT("a", 1), PT("b", 0), PT("b", 1) };
    _to_input(pts, 3);
    dt_masks_point_ellipse_t *e = form->points->data;
    e->center[0] = pts[0] / iw;
    e->center[1] = pts[1] / ih;
    e->radius[0] = fmaxf(hypotf(pts[2] - pts[0], pts[3] - pts[1]) / mind, 0.002f);
    e->radius[1] = fmaxf(hypotf(pts[4] - pts[0], pts[5] - pts[1]) / mind, 0.002f);
    e->rotation = rad2degf(atan2f(pts[3] - pts[1], pts[2] - pts[0]));
    if(json_object_has_member(o, "border"))
      e->border = CLAMP((float)json_object_get_double_member(o, "border"), 0.001f, 4.0f);
  }
#undef PT
  _shape_changed(m);
  _ok_done(_ok());
}

// {"cmd":"shape","module":...} -> the shape in output pixels: for a gradient
// its anchor, a point along the line, the side it fades in toward and its
// compression; for an ellipse its outline and the outline with its border
static void _cmd_shape(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *m = _find_module(json_object_get_string_member_with_default(o, "module", ""));
  dt_masks_form_t *form = m ? _local_shape(m) : NULL;
  if(!form || !form->points) return _error("not a local adjustment");
  const float iw = H.edit.pipe.iwidth, ih = H.edit.pipe.iheight;
  const float mind = fminf(iw, ih), diag = hypotf(iw, ih);
  JsonBuilder *b = _ok();
  if(form->type & DT_MASKS_GROUP)
  {
    // a subject: its traced outlines, each as corner points
    json_builder_set_member_name(b, "kind");
    json_builder_add_string_value(b, "subject");
    json_builder_set_member_name(b, "points");
    json_builder_begin_array(b);
    json_builder_end_array(b);
    json_builder_set_member_name(b, "outlines");
    json_builder_begin_array(b);
    for(GList *l = form->points; l; l = g_list_next(l))
    {
      const dt_masks_point_group_t *gp = l->data;
      dt_masks_form_t *path = dt_masks_get_from_id(&H.edit.dev, gp->formid);
      if(!path || !(path->type & DT_MASKS_PATH)) continue;
      const int n = g_list_length(path->points);
      float *pts = g_new(float, 2 * n);
      int i = 0;
      for(GList *p = path->points; p; p = g_list_next(p))
      {
        const dt_masks_point_path_t *pt = p->data;
        pts[i++] = pt->corner[0] * iw;
        pts[i++] = pt->corner[1] * ih;
      }
      _to_output(pts, n);
      json_builder_begin_array(b);
      for(int k = 0; k < 2 * n; k++) json_builder_add_double_value(b, pts[k]);
      json_builder_end_array(b);
      g_free(pts);
    }
    json_builder_end_array(b);
    _ok_done(b);
    return;
  }
  if(form->type & DT_MASKS_GRADIENT)
  {
    const dt_masks_point_gradient_t *g = form->points->data;
    const float ax = g->anchor[0] * iw, ay = g->anchor[1] * ih;
    const float v = deg2radf(-g->rotation), side = deg2radf(-(g->rotation + 90.0f));
    const float reach = 0.1f * mind, width = g->compression * diag;
    float pts[10] = { ax, ay,
                      ax + reach * cosf(v), ay + reach * sinf(v),
                      ax + reach * cosf(side), ay + reach * sinf(side),
                      ax + width * cosf(side), ay + width * sinf(side),
                      ax - width * cosf(side), ay - width * sinf(side) };
    _to_output(pts, 5);
    json_builder_set_member_name(b, "kind");
    json_builder_add_string_value(b, "gradient");
    json_builder_set_member_name(b, "points");
    json_builder_begin_array(b);
    for(int i = 0; i < 10; i++) json_builder_add_double_value(b, pts[i]);
    json_builder_end_array(b);
    json_builder_set_member_name(b, "compression");
    json_builder_add_double_value(b, g->compression);
  }
  else
  {
    const dt_masks_point_ellipse_t *e = form->points->data;
    const float cx = e->center[0] * iw, cy = e->center[1] * ih;
    const float r = deg2radf(e->rotation);
    const float k = (e->flags & DT_MASKS_ELLIPSE_PROPORTIONAL) ? 1.0f + e->border : 1.0f;
    const float extra = (e->flags & DT_MASKS_ELLIPSE_PROPORTIONAL) ? 0.0f : e->border * mind;
    enum { N = 64 };
    float pts[2 * (2 * N + 3)];
    for(int ring = 0; ring < 2; ring++)
      for(int i = 0; i < N; i++)
      {
        const float t = 2.0f * M_PI_F * i / N;
        const float a = e->radius[0] * mind * (ring ? k : 1.0f) + (ring ? extra : 0.0f);
        const float bb = e->radius[1] * mind * (ring ? k : 1.0f) + (ring ? extra : 0.0f);
        const float x = a * cosf(t), y = bb * sinf(t);
        pts[2 * (ring * N + i)] = cx + x * cosf(r) - y * sinf(r);
        pts[2 * (ring * N + i) + 1] = cy + x * sinf(r) + y * cosf(r);
      }
    // centre and the ends of the two radii
    float *c = pts + 4 * N;
    c[0] = cx; c[1] = cy;
    c[2] = cx + e->radius[0] * mind * cosf(r); c[3] = cy + e->radius[0] * mind * sinf(r);
    c[4] = cx - e->radius[1] * mind * sinf(r); c[5] = cy + e->radius[1] * mind * cosf(r);
    _to_output(pts, 2 * N + 3);
    json_builder_set_member_name(b, "kind");
    json_builder_add_string_value(b, "ellipse");
    json_builder_set_member_name(b, "points");
    json_builder_begin_array(b);
    for(int i = 0; i < 2 * (2 * N + 3); i++) json_builder_add_double_value(b, pts[i]);
    json_builder_end_array(b);
    json_builder_set_member_name(b, "border");
    json_builder_add_double_value(b, e->border);
  }
  _ok_done(b);
}

// {"cmd":"rename_instance","module":"exposure:1","name":"..."}: an instance's
// name, kept in the history and the sidecar
static void _cmd_rename_instance(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *m = _find_module(json_object_get_string_member_with_default(o, "module", ""));
  if(!m) return _error("unknown module");
  g_strlcpy(m->multi_name, json_object_get_string_member_with_default(o, "name", ""), sizeof(m->multi_name));
  m->multi_name_hand_edited = TRUE;
  _commit(m, m->enabled);
  JsonBuilder *b = _ok();
  _add_modules(b);
  _ok_done(b);
}

// ---------------------------------------------------------------- presets

// darktable's module presets live in data.presets: its own (write-protected,
// added by each module's init_presets at startup) and the user's.
// {"cmd":"presets"} -> those for the open photo's modules at their versions,
// without the ones applied automatically (darktable's workflow defaults)
static void _cmd_presets(void)
{
  if(!H.edit.loaded) return _error("no image open");
  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "presets");
  json_builder_begin_array(b);
  GHashTable *seen = g_hash_table_new(g_str_hash, g_str_equal);
  for(GList *l = H.edit.dev.iop; l; l = g_list_next(l))
  {
    dt_iop_module_t *m = l->data;
    if(g_hash_table_contains(seen, m->op)) continue;
    g_hash_table_add(seen, m->op);
    sqlite3_stmt *stmt;
    sqlite3_prepare_v2(dt_database_get(darktable.db),
                       "SELECT name, writeprotect FROM data.presets"
                       " WHERE operation = ?1 AND op_version = ?2 AND autoapply = 0"
                       " ORDER BY writeprotect DESC, LOWER(name)", -1, &stmt, NULL);
    sqlite3_bind_text(stmt, 1, m->op, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(stmt, 2, m->version());
    while(sqlite3_step(stmt) == SQLITE_ROW)
    {
      json_builder_begin_object(b);
      json_builder_set_member_name(b, "op");
      json_builder_add_string_value(b, m->op);
      const char *name = (const char *)sqlite3_column_text(stmt, 0);
      json_builder_set_member_name(b, "name");
      json_builder_add_string_value(b, name);
      // darktable's own presets are stored as "_builtin_<name>" and shown without it
      json_builder_set_member_name(b, "title");
      json_builder_add_string_value(b, g_str_has_prefix(name, "_builtin_") ? name + strlen("_builtin_") : name);
      json_builder_set_member_name(b, "builtin");
      json_builder_add_boolean_value(b, sqlite3_column_int(stmt, 1) != 0);
      json_builder_end_object(b);
    }
    sqlite3_finalize(stmt);
  }
  g_hash_table_destroy(seen);
  json_builder_end_array(b);
  _ok_done(b);
}

// {"cmd":"apply_preset","module":"exposure:0","name":"..."}: its settings
// (and blending, where saved with one) onto that module, as one edit
static void _cmd_apply_preset(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *m = _find_module(json_object_get_string_member_with_default(o, "module", ""));
  if(!m) return _error("unknown module");
  sqlite3_stmt *stmt;
  sqlite3_prepare_v2(dt_database_get(darktable.db),
                     "SELECT op_params, enabled, blendop_params, blendop_version FROM data.presets"
                     " WHERE operation = ?1 AND op_version = ?2 AND name = ?3", -1, &stmt, NULL);
  sqlite3_bind_text(stmt, 1, m->op, -1, SQLITE_TRANSIENT);
  sqlite3_bind_int(stmt, 2, m->version());
  sqlite3_bind_text(stmt, 3, json_object_get_string_member_with_default(o, "name", ""), -1, SQLITE_TRANSIENT);
  if(sqlite3_step(stmt) != SQLITE_ROW)
  {
    sqlite3_finalize(stmt);
    return _error("no such preset");
  }
  const void *params = sqlite3_column_blob(stmt, 0);
  const int size = sqlite3_column_bytes(stmt, 0);
  const gboolean enabled = sqlite3_column_int(stmt, 1) != 0;
  const void *blend = sqlite3_column_blob(stmt, 2);
  const int blend_size = sqlite3_column_bytes(stmt, 2);
  const int blend_version = sqlite3_column_int(stmt, 3);
  if(!params || size != m->params_size)
  {
    sqlite3_finalize(stmt);
    return _error("this preset is for another version of the module");
  }
  memcpy(m->params, params, size);
  if(blend && m->blend_params && blend_version == dt_develop_blend_version()
     && blend_size == sizeof(dt_develop_blend_params_t))
    dt_iop_commit_blend_params(m, (const dt_develop_blend_params_t *)blend);
  sqlite3_finalize(stmt);
  _commit(m, enabled);
  JsonBuilder *b = _ok();
  _add_modules(b);
  _ok_done(b);
}

// {"cmd":"save_preset","module":"exposure:0","name":"..."}: the module's
// settings as a user preset, as darktable's "store new preset" does with its
// defaults (any camera, lens and exposure; not applied automatically)
static void _cmd_save_preset(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *m = _find_module(json_object_get_string_member_with_default(o, "module", ""));
  const char *name = json_object_get_string_member_with_default(o, "name", "");
  if(!m) return _error("unknown module");
  if(!*name) return _error("a preset needs a name");
  sqlite3_stmt *stmt;
  // a darktable preset of the same name stays as it is
  sqlite3_prepare_v2(dt_database_get(darktable.db),
                     "SELECT 1 FROM data.presets WHERE operation = ?1 AND op_version = ?2 AND name = ?3 AND writeprotect = 1",
                     -1, &stmt, NULL);
  sqlite3_bind_text(stmt, 1, m->op, -1, SQLITE_TRANSIENT);
  sqlite3_bind_int(stmt, 2, m->version());
  sqlite3_bind_text(stmt, 3, name, -1, SQLITE_TRANSIENT);
  const gboolean protected_name = sqlite3_step(stmt) == SQLITE_ROW;
  sqlite3_finalize(stmt);
  if(protected_name) return _error("darktable has a preset with that name");
  sqlite3_prepare_v2(dt_database_get(darktable.db),
                     "INSERT OR REPLACE INTO data.presets"
                     " (name, description, model, maker, lens, iso_min, iso_max, exposure_min, exposure_max,"
                     "  aperture_min, aperture_max, focal_length_min, focal_length_max, autoapply,"
                     "  filter, format, def, writeprotect, operation, op_version, op_params, enabled,"
                     "  blendop_params, blendop_version, multi_priority, multi_name, multi_name_hand_edited)"
                     " VALUES (?1, '', '%', '%', '%', 0, 340282346638528859811704183484516925440.0, 0, 100000000,"
                     "  0, 100000000, 0, 1000, 0, 0, 0, 0, 0, ?2, ?3, ?4, ?5, ?6, ?7, 0, '', 0)",
                     -1, &stmt, NULL);
  sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 2, m->op, -1, SQLITE_TRANSIENT);
  sqlite3_bind_int(stmt, 3, m->version());
  sqlite3_bind_blob(stmt, 4, m->params, m->params_size, SQLITE_TRANSIENT);
  sqlite3_bind_int(stmt, 5, m->enabled);
  if(m->blend_params)
    sqlite3_bind_blob(stmt, 6, m->blend_params, sizeof(dt_develop_blend_params_t), SQLITE_TRANSIENT);
  else
    sqlite3_bind_null(stmt, 6);
  sqlite3_bind_int(stmt, 7, dt_develop_blend_version());
  const int rc = sqlite3_step(stmt);
  sqlite3_finalize(stmt);
  if(rc != SQLITE_DONE) return _error("couldn't save the preset");
  _ok_done(_ok());
}

// {"cmd":"delete_preset","op":"exposure","name":"..."}: a user preset only
static void _cmd_delete_preset(JsonObject *o)
{
  sqlite3_stmt *stmt;
  sqlite3_prepare_v2(dt_database_get(darktable.db),
                     "DELETE FROM data.presets WHERE operation = ?1 AND name = ?2 AND writeprotect = 0", -1, &stmt, NULL);
  sqlite3_bind_text(stmt, 1, json_object_get_string_member_with_default(o, "op", ""), -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 2, json_object_get_string_member_with_default(o, "name", ""), -1, SQLITE_TRANSIENT);
  sqlite3_step(stmt);
  sqlite3_finalize(stmt);
  _ok_done(_ok());
}

// ------------------------------------------------------------ film looks

// Film looks are Hald CLUTs (or .cube files) applied by darktable's LUT 3D
// module, whose file paths are relative to its LUT folder setting.
// {"cmd":"look","folder":"/path","file":"Color/Kodak/Kodak Portra 400.png","strength":80}
// applies one; "file":"" switches the look off. Most film LUTs are made for
// display-referred sRGB, so the module moves after the tone mapper (darktable
// places it before, for scene-referred LUTs). Strength is its blend opacity.
// Without "file" or "strength" it only reports the current look.
static dt_iop_module_t *_first_module(const char *op)
{
  for(GList *l = H.edit.dev.iop; l; l = g_list_next(l))
  {
    dt_iop_module_t *m = l->data;
    if(!strcmp(m->op, op) && m->multi_priority == 0) return m;
  }
  return NULL;
}

// An HDR source (a gain map, HLG or PQ image, or Apple's rendering of a raw,
// decoded by macOS) is already rendered: SDR white at 1.0, highlights above,
// and no tone mapper. darktable's PQ and HLG output profiles put 1.0 at the
// format's peak (10,000 or 1,000 nits), so such a photo would come out over
// two stops too bright with everything above SDR white clipped. Two instances
// named "HDR white", just before the output profile, place it for an HDR
// profile: exposure brings SDR white to the reference white (203 nits), and
// for HLG, levels on luminance undoes the HLG display's system gamma (1.2),
// which would otherwise darken the midtones (BT.2100's inverse OOTF). They're
// off for an SDR profile. With a tone mapper on, they're off too: its output
// is display-referred in darktable's own terms (target white 100% is the
// format's 1.0, as for a raw), so it works on an HDR source as it does on a
// raw. They go into the history with the profile or tone mapper change,
// so undo takes all of it back together; the app hides them.
#define HDR_WHITE_NAME "HDR white"

// the start of dt_iop_rgblevels_params_t in iop/rgblevels.c (not in a header)
typedef struct dt_iop_rgblevels_params_head_t
{
  int autoscale;              // DT_IOP_RGBLEVELS_LINKED_CHANNELS = 0
  int preserve_colors;        // DT_RGB_NORM_LUMINANCE = 1
  float levels[3][3];
} dt_iop_rgblevels_params_head_t;

// the HDR white instance of a module, made (off, before the output profile) if asked
static dt_iop_module_t *_hdr_white_instance(const char *op, dt_iop_module_t *colorout, const gboolean make)
{
  for(GList *l = H.edit.dev.iop; l; l = g_list_next(l))
  {
    dt_iop_module_t *x = l->data;
    if(!strcmp(x->op, op) && !strcmp(x->multi_name, HDR_WHITE_NAME)) return x;
  }
  dt_iop_module_t *base = _first_module(op);
  if(!make || !base) return NULL;
  dt_dev_add_history_item_ext(&H.edit.dev, base, FALSE, TRUE);
  dt_iop_module_t *m = dt_dev_module_duplicate(&H.edit.dev, base);
  if(!m) return NULL;
  dt_iop_reload_defaults(m);
  g_strlcpy(m->multi_name, HDR_WHITE_NAME, sizeof(m->multi_name));
  m->multi_name_hand_edited = TRUE;
  m->enabled = FALSE;
  dt_ioppr_move_iop_before(&H.edit.dev, m, colorout);
  return m;
}

static void _sync_hdr_white(void)
{
  dt_iop_module_t *colorout = _first_module("colorout");
  if(!colorout) return;
  dt_introspection_field_t *tf = _find_field(colorout, "type");
  const int type = tf ? *(int *)((char *)colorout->params + tf->header.offset) : DT_COLORSPACE_SRGB;
  gboolean mapped = FALSE;
  static const char *mappers[] = { "sigmoid", "filmicrgb", "agx", "basecurve" };
  for(GList *l = H.edit.dev.iop; l && !mapped; l = g_list_next(l))
  {
    const dt_iop_module_t *x = l->data;
    for(int i = 0; i < 4; i++) if(x->enabled && !strcmp(x->op, mappers[i])) mapped = TRUE;
  }
  const gboolean hlg = !mapped && (type == DT_COLORSPACE_HLG_REC2020 || type == DT_COLORSPACE_HLG_P3);
  const gboolean pq = !mapped && (type == DT_COLORSPACE_PQ_REC2020 || type == DT_COLORSPACE_PQ_P3);
  const float ev = hlg ? log2f(203.0f / 1000.0f) : pq ? log2f(203.0f / 10000.0f) : 0.0f;
  // levels' grey point for an exponent of 1/1.2: inv_gamma = 10^((grey - 0.5) / 0.5)
  const float grey = 0.5f + 0.5f * log10f(1.0f / 1.2f);
  gboolean changed = FALSE;

  dt_iop_module_t *exposure = _hdr_white_instance("exposure", colorout, ev != 0.0f);
  dt_introspection_field_t *ef = exposure ? _find_field(exposure, "exposure") : NULL;
  if(ef && (exposure->enabled != (ev != 0.0f)
            || fabsf(*(float *)((char *)exposure->params + ef->header.offset) - ev) > 1e-4f))
  {
    // a plain scale: manual, no black offset, no exposure bias or highlight compensation
    memcpy(exposure->params, exposure->default_params, exposure->params_size);
    *(float *)((char *)exposure->params + ef->header.offset) = ev;
    const char *off[] = { "compensate_exposure_bias", "compensate_hilite_pres" };
    for(int i = 0; i < 2; i++)
    {
      dt_introspection_field_t *f = _find_field(exposure, off[i]);
      if(f) *(gboolean *)((char *)exposure->params + f->header.offset) = FALSE;
    }
    exposure->enabled = ev != 0.0f;
    dt_dev_add_history_item_ext(&H.edit.dev, exposure, exposure->enabled, TRUE);
    changed = TRUE;
  }

  dt_iop_module_t *levels = _hdr_white_instance("rgblevels", colorout, hlg);
  if(levels && levels->enabled != hlg)
  {
    dt_iop_rgblevels_params_head_t *p = levels->params;
    memcpy(levels->params, levels->default_params, levels->params_size);
    p->autoscale = 0;           // linked channels
    p->preserve_colors = 1;     // luminance
    p->levels[0][0] = 0.0f;
    p->levels[0][1] = grey;
    p->levels[0][2] = 1.0f;
    levels->enabled = hlg;
    dt_dev_add_history_item_ext(&H.edit.dev, levels, levels->enabled, TRUE);
    changed = TRUE;
  }

  if(!changed) return;
  H.edit.dirty = TRUE;
  dt_dev_pixelpipe_cleanup_nodes(&H.edit.pipe);
  dt_dev_pixelpipe_create_nodes(&H.edit.pipe, &H.edit.dev);
  dt_dev_pixelpipe_synch_all(&H.edit.pipe, &H.edit.dev);
  dt_dev_pixelpipe_cache_flush(&H.edit.pipe);
}

static void _cmd_look(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *m = _first_module("lut3d");
  if(!m) return _error("darktable's LUT 3D module isn't available");
  const char *folder = json_object_get_string_member_with_default(o, "folder", "");
  if(*folder) dt_conf_set_string("plugins/darkroom/lut3d/def_path", folder);
  const char *file = json_object_get_string_member_with_default(o, "file", NULL);

  dt_introspection_field_t *f = _find_field(m, "filepath");
  if(!f) return _error("unexpected LUT 3D layout");
  gboolean reordered = FALSE;
  const gboolean change = file || json_object_has_member(o, "strength");
  if(!change)
  {
    // only asking what the look is
  }
  else if(file && !*file)
  {
    m->enabled = FALSE;
    _commit(m, FALSE);
  }
  else
  {
    if(file)
    {
      g_strlcpy((char *)m->params + f->header.offset, file, f->Array.count);
      dt_introspection_field_t *cs = _find_field(m, "colorspace");
      if(cs) *(int *)((char *)m->params + cs->header.offset) = 0;   // sRGB
      // after the tone mapper in use
      static const char *mappers[] = { "sigmoid", "filmicrgb", "agx", "basecurve" };
      for(int i = 0; i < 4; i++)
      {
        dt_iop_module_t *tm = _first_module(mappers[i]);
        if(tm && tm->enabled && m->iop_order < tm->iop_order)
        {
          reordered = dt_ioppr_move_iop_after(&H.edit.dev, m, tm);
          break;
        }
      }
    }
    if(json_object_has_member(o, "strength") && m->blend_params)
    {
      m->blend_params->mask_mode = DEVELOP_MASK_ENABLED;
      m->blend_params->opacity = CLAMP((float)json_object_get_double_member(o, "strength"), 0.0f, 100.0f);
    }
    _commit(m, TRUE);
  }
  if(reordered)
  {
    dt_dev_pixelpipe_cleanup_nodes(&H.edit.pipe);
    dt_dev_pixelpipe_create_nodes(&H.edit.pipe, &H.edit.dev);
    dt_dev_pixelpipe_synch_all(&H.edit.pipe, &H.edit.dev);
    dt_dev_pixelpipe_cache_flush(&H.edit.pipe);
  }
  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "file");
  json_builder_add_string_value(b, m->enabled ? (const char *)m->params + f->header.offset : "");
  json_builder_set_member_name(b, "strength");
  json_builder_add_double_value(b, m->blend_params ? m->blend_params->opacity : 100.0);
  _add_modules(b);
  _ok_done(b);
}

static void _cmd_styles(void)
{
  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "styles");
  json_builder_begin_array(b);
  GList *styles = dt_styles_get_list("");
  for(GList *l = styles; l; l = g_list_next(l))
  {
    const dt_style_t *st = l->data;
    json_builder_add_string_value(b, st->name);
  }
  g_list_free_full(styles, dt_style_free);
  json_builder_end_array(b);
  _ok_done(b);
}

static void _cmd_apply_style(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  const char *name = json_object_get_string_member_with_default(o, "name", "");
  if(!dt_styles_exists(name)) return _error("unknown style");

  // styles apply to the history in the library, so flush ours there first,
  // append the style (darktable's default mode), then reload. The history
  // length before is returned so the app can step back to it (undo).
  const int end_before = H.edit.dev.history_end;
  dt_dev_write_history(&H.edit.dev);
  dt_styles_apply_to_image(name, FALSE, FALSE, H.imgid);
  const char *err = _load(H.imgid);
  if(err) return _error(err);

  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "historyEndBefore");
  json_builder_add_int_value(b, end_before);
  _add_modules(b);
  _ok_done(b);
}

// --------------------------------------------- tone equalizer mask fitting
// darktable fits the tone equalizer's mask to each photo with two "wand"
// buttons in its interface (toneequal.c, auto_adjust_exposure_boost and
// auto_adjust_contrast_boost), using a histogram the interface collects. This
// reproduces them headless: render the image as it reaches the tone
// equalizer, build darktable's luminance mask, take the same 5th and 95th
// percentiles and apply the same formulas.

#define TE_FULCRUM exp2f(-4.0f)
// dt_iop_toneequalizer_filter_t is private to toneequal.c; same values
enum { TE_GUIDED = 2, TE_EIGF = 4 };

// darktable's percentile search (compute_log_histogram_and_stats)
static void _te_percentiles(const float *lum, const size_t n, float *first, float *last)
{
  enum { BINS = 512 };   // 2 x UI_SAMPLES, over [-10, +6] EV
  int hist[BINS] = { 0 };
  for(size_t k = 0; k < n; k++)
    hist[CLAMP((int)(((log2f(lum[k]) + 10.0f) / 16.0f) * BINS), 0, BINS - 1)]++;
  const size_t lo = n * 0.05f, hi = n * 0.05f;
  size_t pop = 0; int fp = 0, lp = 0;
  for(int k = 0; k < BINS; k++) { const size_t prev = pop; pop += hist[k]; if(prev < lo && lo <= pop) { fp = k; break; } }
  pop = 0;
  for(int k = BINS - 1; k >= 0; k--) { const size_t prev = pop; pop += hist[k]; if(prev < hi && hi <= pop) { lp = k; break; } }
  *first = 16.0f * fp / (BINS - 1) - 10.0f;
  *last = 16.0f * lp / (BINS - 1) - 10.0f;
}

// The image as it arrives at a module, as float RGBA at up to 900 px, in a
// throwaway pipe so the preview's cache is untouched. The downscale also
// averages out noise, much like darktable's denoised colour picker.
// Returns a buffer to free with dt_free_align, or NULL.
static float *_render_module_input(dt_iop_module_t *module, int *out_w, int *out_h)
{
  dt_dev_pixelpipe_t pipe;
  if(!dt_dev_pixelpipe_init_cached(&pipe, 0, 4, 0)) return NULL;
  pipe.type = DT_DEV_PIXELPIPE_FULL;
  dt_dev_pixelpipe_set_input(&pipe, &H.edit.dev, (float *)H.edit.buf.buf,
                             H.edit.buf.width, H.edit.buf.height, H.edit.buf.iscale);
  dt_dev_pixelpipe_create_nodes(&pipe, &H.edit.dev);
  dt_dev_pixelpipe_synch_all(&pipe, &H.edit.dev);
  dt_dev_pixelpipe_get_dimensions(&pipe, &H.edit.dev, pipe.iwidth, pipe.iheight,
                                  &pipe.processed_width, &pipe.processed_height);
  dt_dev_pixelpipe_disable_after(&pipe, module->op);
  for(GList *l = pipe.nodes; l; l = g_list_next(l))
  {
    dt_dev_pixelpipe_iop_t *piece = l->data;
    if(piece->module == module) piece->enabled = FALSE;
  }
  const float scale = fminf(1.0f, 900.0f / MAX(pipe.processed_width, pipe.processed_height));
  const int w = scale * pipe.processed_width, h = scale * pipe.processed_height;
  int tries = 0;
  while(dt_dev_pixelpipe_process_no_gamma(&pipe, &H.edit.dev, 0, 0, w, h, scale) && ++tries < 3);
  float *copy = NULL;
  if(pipe.backbuf && pipe.backbuf_bpp >= 4 * sizeof(float))
  {
    copy = dt_alloc_align_float((size_t)4 * w * h);
    memcpy(copy, pipe.backbuf, sizeof(float) * 4 * w * h);
  }
  dt_dev_pixelpipe_cleanup(&pipe);
  *out_w = w;
  *out_h = h;
  return copy;
}

static float _param_float(dt_iop_module_t *m, const char *name, float fallback)
{
  const dt_introspection_field_t *f = _find_field(m, name);
  return f ? *(const float *)((const char *)m->params + f->header.offset) : fallback;
}

static void _set_param_float(dt_iop_module_t *m, const char *name, float v)
{
  const dt_introspection_field_t *f = _find_field(m, name);
  if(f) *(float *)((char *)m->params + f->header.offset) = v;
}

static int _cmp_float(const void *a, const void *b)
{
  const float x = *(const float *)a, y = *(const float *)b;
  return (x > y) - (x < y);
}

// filmic's "auto tune levels" (filmicrgb.c apply_autotune) over the whole
// image: white and black relative exposure from the brightest and darkest
// levels (max RGB of the per-channel extremes), scaled by dynamic range
// scaling; hardness recomputed as darktable does.
static void _cmd_filmic_autotune(void)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *fm = _find_module("filmicrgb:0");
  if(!fm) return _error("no filmic rgb");
  int w, h;
  float *px = _render_module_input(fm, &w, &h);
  if(!px) return _error("could not render filmic's input");

  // darktable's picker takes per-channel extremes of a denoised sample; here
  // the 0.05th and 99.95th percentiles per channel play that part, so a few
  // stray near-black or negative pixels can't pin black at -16 EV
  const size_t n = (size_t)w * h;
  float mx[3], mn[3];
  float *chan = dt_alloc_align_float(n);
  for(int c = 0; c < 3; c++)
  {
    for(size_t k = 0; k < n; k++) chan[k] = px[4 * k + c];
    qsort(chan, n, sizeof(float), _cmp_float);   // fine at 900 px
    mn[c] = chan[(size_t)(n * 0.0005)];
    mx[c] = chan[MIN(n - 1, (size_t)(n * 0.9995))];
  }
  dt_free_align(chan);
  dt_free_align(px);

  const float grey = _param_float(fm, "grey_point_source", 18.45f) / 100.0f;
  const float security = _param_float(fm, "security_factor", 0.0f);
  const float white = fmaxf(fmaxf(mx[0], mx[1]), mx[2]);
  const float black = fmaxf(fmaxf(fmaxf(mn[0], mn[1]), mn[2]), 1e-9f);
  float ev_max = CLAMP(log2f(white / grey), 1.0f, 16.0f) * (1.0f + security / 100.0f);
  float ev_min = CLAMP(log2f(black / grey), -16.0f, -1.0f) * (1.0f + security / 100.0f);
  ev_min = fmaxf(ev_min, -16.0f);
  _set_param_float(fm, "white_point_source", ev_max);
  _set_param_float(fm, "black_point_source", ev_min);

  // _compute_output_power
  const dt_introspection_field_t *pf = _find_field(fm, "output_power");
  if(pf)
  {
    const float target = _param_float(fm, "grey_point_target", 18.45f) / 100.0f;
    const float power = logf(target) / logf(-ev_min / (ev_max - ev_min));
    _set_param_float(fm, "output_power", CLAMP(power, pf->Float.Min, pf->Float.Max));
  }
  _commit(fm, TRUE);

  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "whiteEV");
  json_builder_add_double_value(b, ev_max);
  json_builder_set_member_name(b, "blackEV");
  json_builder_add_double_value(b, ev_min);
  _add_modules(b);
  _ok_done(b);
}

static void _cmd_toneequal_fit(void)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *te = _find_module("toneequal:0");
  if(!te) return _error("no tone equalizer");

  int w, h;
  float *input = _render_module_input(te, &w, &h);
  if(!input) return _error("could not render the tone equalizer's input");

  // darktable's luminance mask with no compensation applied, then percentiles
  const dt_introspection_field_t *mf = _find_field(te, "method");
  const int method = mf ? *(const int *)((const char *)te->params + mf->header.offset) : DT_TONEEQ_NORM_2;
  float *lum = dt_alloc_align_float((size_t)w * h);
  luminance_mask(input, lum, w, h, method, 1.0f, TE_FULCRUM, 1.0f);
  float first, last;
  _te_percentiles(lum, (size_t)w * h, &first, &last);
  dt_free_align(lum);
  dt_free_align(input);

  // darktable's formulas: map the 5th to 95th percentile onto [-7, -1] EV
  const float fd = exp2f(first), ld = exp2f(last);
  const float s1 = TE_FULCRUM - exp2f(-7.0f), s2 = exp2f(-1.0f) - TE_FULCRUM;
  const float mix = fd * s2 + ld * s1;
  const float exposure_boost = log2f(TE_FULCRUM * (s1 + s2) / mix);
  float contrast_boost = log2f(mix / (TE_FULCRUM * (ld - fd)));

  // darktable's regression correction for its smoothing filters
  const dt_introspection_field_t *df = _find_field(te, "details");
  const dt_introspection_field_t *ff = _find_field(te, "feathering");
  const int details = df ? *(const int *)((const char *)te->params + df->header.offset) : 0;
  const float feathering = ff ? *(const float *)((const char *)te->params + ff->header.offset) : 1.0f;
  if(details == TE_EIGF && contrast_boost > 0.0f)
  {
    const float correction = -0.0276f + 0.01823f * feathering + (0.7566f - 1.0f) * contrast_boost;
    if(feathering < 5.0f) contrast_boost += correction;
    else if(feathering < 10.0f) contrast_boost += correction * (2.0f - feathering / 5.0f);
  }
  else if(details == TE_GUIDED && contrast_boost > 0.0f)
    contrast_boost = 0.0235f + 1.1225f * contrast_boost;

  // write both into the module and the history
  const char *names[2] = { "exposure_boost", "contrast_boost" };
  const float values[2] = { CLAMP(exposure_boost, -16.0f, 16.0f), CLAMP(contrast_boost, -16.0f, 16.0f) };
  for(int i = 0; i < 2; i++)
  {
    const dt_introspection_field_t *f = _find_field(te, names[i]);
    if(f) *(float *)((char *)te->params + f->header.offset) = values[i];
  }
  _commit(te, TRUE);

  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "firstPercentileEV");
  json_builder_add_double_value(b, first);
  json_builder_set_member_name(b, "lastPercentileEV");
  json_builder_add_double_value(b, last);
  _add_modules(b);
  _ok_done(b);
}

// --------------------------------------------------------------- export
// The same path as darktable-cli: write the edit to the library, then
// darktable's "disk" storage and a format module (jpeg, png, tiff, webp, jxl,
// heif). Format settings are read from darktable's config keys, so they are
// set there first. The colour profile is the edit's own (output color
// profile module), so HDR profiles carry through to formats that support them.

static void _cmd_export(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  const char *path = json_object_get_string_member_with_default(o, "path", NULL);
  const char *fmt = json_object_get_string_member_with_default(o, "format", "jpeg");
  const int quality = json_object_get_int_member_with_default(o, "quality", 90);
  const int bpp = json_object_get_int_member_with_default(o, "bpp", 8);
  const int max = json_object_get_int_member_with_default(o, "max", 0);
  // a dt_colorspaces_color_profile_type_t, or -1 for the edit's own output profile
  const int icc = json_object_get_int_member_with_default(o, "icc", -1);
  if(!path) return _error("no output path");

  static const char *formats[] = { "jpeg", "png", "tiff", "webp", "jxl", "heif" };
  gboolean known = FALSE;
  for(size_t i = 0; i < G_N_ELEMENTS(formats); i++) known |= !strcmp(fmt, formats[i]);
  if(!known) return _error("unsupported format");

  // format settings, as darktable's export module would have stored them
  gchar *key = NULL;
  #define SET_INT(fmtname, name, v) do { key = g_strdup_printf("plugins/imageio/format/%s/%s", fmtname, name); \
                                         dt_conf_set_int(key, v); g_free(key); } while(0)
  if(!strcmp(fmt, "jpeg")) SET_INT("jpeg", "quality", quality);
  if(!strcmp(fmt, "webp")) { SET_INT("webp", "quality", quality); SET_INT("webp", "comp_type", quality >= 100 ? 1 : 0); }
  if(!strcmp(fmt, "heif")) { SET_INT("heif", "quality", quality); SET_INT("heif", "bitdepth", bpp); }
  if(!strcmp(fmt, "jxl"))  { SET_INT("jxl", "quality", quality); SET_INT("jxl", "bpp", bpp); }
  if(!strcmp(fmt, "png"))  SET_INT("png", "bpp", bpp);
  if(!strcmp(fmt, "tiff")) SET_INT("tiff", "bpp", bpp);
  #undef SET_INT
  dt_conf_set_int("plugins/imageio/storage/disk/overwrite", 1);   // the app's save panel asked already

  // export reads the history from the library, so put the edit there
  dt_dev_write_history(&H.edit.dev);

  dt_imageio_module_storage_t *storage = dt_imageio_get_storage_by_name("disk");
  // the JPEG XL module's file is libjpegxl, though its settings live under "jxl"
  dt_imageio_module_format_t *format = dt_imageio_get_format_by_name(!strcmp(fmt, "jxl") ? "jpegxl" : fmt);
  if(!storage || !format) return _error("export modules are missing");
  dt_imageio_module_data_t *sdata = storage->get_params(storage);
  dt_imageio_module_data_t *fdata = format->get_params(format);
  if(!sdata || !fdata) return _error("could not set up the export");
  // darktable-cli does the same: the disk storage's params start with its filename pattern
  g_strlcpy((char *)sdata, path, DT_MAX_PATH_FOR_PARAMS);
  fdata->max_width = MAX(max, 0);
  fdata->max_height = MAX(max, 0);
  // frames and watermarks are drawn by the app (ExportExtras), not darktable's
  // framing and watermark modules, which need Cairo
  fdata->style[0] = '\0';
  fdata->style_append = 1;

  GList *ids = g_list_append(NULL, GINT_TO_POINTER(H.imgid));
  if(storage->initialize_store)
  {
    storage->initialize_store(storage, sdata, &format, &fdata, &ids, TRUE, FALSE);
    format->set_params(format, fdata, format->params_size(format));
    storage->set_params(storage, sdata, storage->params_size(storage));
  }
  dt_export_metadata_t metadata = { .flags = dt_lib_export_metadata_default_flags(), .list = NULL };
  const double t0 = dt_get_wtime();
  const int failed = storage->store(storage, sdata, H.imgid, format, fdata, 1, 1, TRUE, FALSE, FALSE, 1.0,
                                    FALSE, icc >= 0 ? (dt_colorspaces_color_profile_type_t)icc : DT_COLORSPACE_NONE,
                                    NULL, DT_INTENT_LAST, &metadata);
  gchar *file = g_strdup_printf("%s.%s", path, format->extension(fdata));
  if(storage->finalize_store) storage->finalize_store(storage, sdata);
  storage->free_params(storage, sdata);
  format->free_params(format, fdata);
  g_list_free(ids);

  if(failed || !g_file_test(file, G_FILE_TEST_IS_REGULAR))
  {
    g_free(file);
    return _error("darktable could not export the photo");
  }
  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "file");
  json_builder_add_string_value(b, file);
  json_builder_set_member_name(b, "ms");
  json_builder_add_int_value(b, (gint64)((dt_get_wtime() - t0) * 1000));
  _ok_done(b);
  g_free(file);
}

// Steps the edit's history back (or forward) to n items, as darktable's
// history stack does; the next edit discards anything beyond n.
static void _cmd_history_end(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  const int n = CLAMP((int)json_object_get_int_member_with_default(o, "end", 0), 0,
                      (int)g_list_length(H.edit.dev.history));
  dt_dev_pop_history_items_ext(&H.edit.dev, n);
  H.edit.dirty = TRUE;
  JsonBuilder *b = _ok();
  _add_modules(b);
  _ok_done(b);
}

// Discards the edit and reloads, so darktable applies its defaults as it
// does for a new photo (its own "discard history").
static void _cmd_reset_all(void)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_history_delete_on_image_ext(H.imgid, FALSE, TRUE);
  const char *err = _load(H.imgid);
  if(err) return _error(err);
  JsonBuilder *b = _ok();
  _add_modules(b);
  _ok_done(b);
}

// Geotags a photo, open or not, as darktable's map view does: the location
// goes into darktable's library and the XMP sidecar (Xmp.exif.GPSLatitude
// and GPSLongitude), never into the raw. Any edit in an existing sidecar is
// read on import and written back unchanged. Without "lat"/"lon" the
// location is removed. {"cmd":"set_location","path":...,"lat":51.5,"lon":-0.12}
// a photo in darktable's library, by path, for writing its sidecar
static dt_imgid_t _import_path(const char *path)
{
  if(!path || !g_file_test(path, G_FILE_TEST_IS_REGULAR)) return NO_IMGID;
  gchar *dir = g_path_get_dirname(path);
  dt_film_t film;
  const dt_filmid_t filmid = dt_film_new(&film, dir);
  g_free(dir);
  return dt_image_import(filmid, path, TRUE, FALSE);
}

static gboolean _write_sidecar(const dt_imgid_t imgid)
{
  // as _cmd_save: sidecars are written only on request
  dt_conf_set_string("write_sidecar_files", "on import");
  const gboolean failed = dt_image_write_sidecar_file(imgid);
  dt_conf_set_string("write_sidecar_files", "never");
  return !failed;
}

// ------------------------------------------------------- copy and paste

// Pastes adjustments with darktable's own history copy, which carries
// instances, masks and module order:
// {"cmd":"paste","source":"/a.NEF","modules":["exposure:0",...],"targets":["/b.NEF",...]}
// Without "modules" it copies as darktable's Copy does: every module the
// source has changed, except those unsafe between photos (white balance, lens
// correction, orientation, raw preparation). Pasting merges: the modules
// copied replace the same ones on the target and the rest are kept. Targets
// other than the open photo get their sidecar written; the open photo is
// reloaded, its history extended so the app's undo steps back over the paste.
static void _cmd_paste(JsonObject *o)
{
  const char *source = json_object_get_string_member_with_default(o, "source", "");
  JsonArray *targets = json_object_has_member(o, "targets") ? json_object_get_array_member(o, "targets") : NULL;
  if(!*source || !targets) return _error("nothing to paste");

  gchar *open_path = NULL;
  if(H.edit.loaded)
  {
    char p[PATH_MAX] = { 0 };
    gboolean from_cache = FALSE;
    dt_image_full_path(H.imgid, p, sizeof(p), &from_cache);
    open_path = g_strdup(p);
  }
  const gboolean source_is_open = open_path && !g_strcmp0(open_path, source);
  // the open photo's edits go to the library first, as the copy reads them from there
  if(H.edit.loaded) dt_dev_write_history(&H.edit.dev);
  const dt_imgid_t src = source_is_open ? H.imgid : _import_path(source);
  if(!dt_is_valid_imgid(src)) { g_free(open_path); return _error("couldn't read the photo to copy from"); }

  // chosen modules, as indices of their last history item (darktable's form)
  GList *ops = NULL;
  if(json_object_has_member(o, "modules"))
  {
    if(!source_is_open) { g_free(open_path); return _error("choosing adjustments needs the photo open"); }
    JsonArray *mods = json_object_get_array_member(o, "modules");
    for(guint k = 0; k < json_array_get_length(mods); k++)
    {
      dt_iop_module_t *m = _find_module(json_array_get_string_element(mods, k));
      int index = -1, n = 0;
      for(GList *h = H.edit.dev.history; h && n < H.edit.dev.history_end; h = g_list_next(h), n++)
        if(((dt_dev_history_item_t *)h->data)->module == m) index = n;
      if(index >= 0) ops = g_list_append(ops, GINT_TO_POINTER(index));
    }
    if(!ops) { g_free(open_path); return _error("none of those adjustments are in this photo's edit"); }
  }

  int pasted = 0;
  gboolean open_changed = FALSE;
  for(guint k = 0; k < json_array_get_length(targets); k++)
  {
    const char *path = json_array_get_string_element(targets, k);
    const gboolean is_open = open_path && !g_strcmp0(open_path, path);
    const dt_imgid_t dst = is_open ? H.imgid : _import_path(path);
    if(!dt_is_valid_imgid(dst) || dst == src) continue;
    if(!dt_history_copy_and_paste_on_image(src, dst, TRUE, ops, TRUE, FALSE, FALSE))
      continue;   // FALSE means not pasted
    pasted++;
    if(is_open) open_changed = TRUE;
    else _write_sidecar(dst);
  }
  g_list_free(ops);
  g_free(open_path);

  if(open_changed)
  {
    const char *err = _load(H.imgid);
    if(err) return _error(err);
  }
  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "pasted");
  json_builder_add_int_value(b, pasted);
  if(open_changed) _add_modules(b);
  _ok_done(b);
}

// Sets a photo's title, caption, keywords and/or rating in its sidecar, as
// darktable's metadata, tagging and rating tools do.
// {"cmd":"set_info","path":...,"title":"...","caption":"...","addTag":"...","removeTag":"...","rating":3}
// Rating is 0-5 stars, or -1 for rejected.
static void _cmd_set_info(JsonObject *o)
{
  const dt_imgid_t imgid = _import_path(json_object_get_string_member_with_default(o, "path", NULL));
  if(!dt_is_valid_imgid(imgid)) return _error("darktable could not import this file");
  if(json_object_has_member(o, "title"))
  {
    const char *title = json_object_get_string_member_with_default(o, "title", "");
    dt_metadata_set(imgid, "Xmp.dc.title", title, FALSE);
  }
  if(json_object_has_member(o, "caption"))
  {
    const char *caption = json_object_get_string_member_with_default(o, "caption", "");
    dt_metadata_set(imgid, "Xmp.dc.description", caption, FALSE);
  }
  // keywords are darktable tags (dc:subject and lr:hierarchicalSubject in the sidecar)
  if(json_object_has_member(o, "addTag"))
  {
    guint tagid = 0;
    if(dt_tag_new(json_object_get_string_member_with_default(o, "addTag", ""), &tagid) || tagid)
      dt_tag_attach(tagid, imgid, FALSE, FALSE);
  }
  if(json_object_has_member(o, "removeTag"))
    dt_tag_detach_by_string(json_object_get_string_member_with_default(o, "removeTag", ""), imgid, FALSE, FALSE);
  if(json_object_has_member(o, "rating"))
  {
    const int rating = json_object_get_int_member(o, "rating");
    dt_ratings_apply_on_image(imgid, rating < 0 ? 6 /* DT_VIEW_REJECT, views/view.h */ : CLAMP(rating, 0, 5), FALSE, FALSE, FALSE);
  }
  if(!_write_sidecar(imgid)) return _error("could not write the XMP sidecar");
  _ok_done(_ok());
}

static void _cmd_set_location(JsonObject *o)
{
  const char *path = json_object_get_string_member_with_default(o, "path", NULL);
  const dt_imgid_t imgid = _import_path(path);
  if(!dt_is_valid_imgid(imgid)) return _error("darktable could not import this file");

  const gboolean remove = !json_object_has_member(o, "lat") || !json_object_has_member(o, "lon");
  const dt_image_geoloc_t geoloc = {
    .longitude = remove ? NAN : json_object_get_double_member(o, "lon"),
    .latitude = remove ? NAN : json_object_get_double_member(o, "lat"),
    .elevation = NAN,
  };
  dt_image_set_location(imgid, &geoloc, FALSE, FALSE);
  if(!_write_sidecar(imgid)) return _error("could not write the XMP sidecar");
  _ok_done(_ok());
}

// ------------------------------------------------------------- rgb curve
// rgbcurve's params, as in iop/rgbcurve.c (private there); checked against
// the module's params_size before use
#define RGBCURVE_MAXNODES 20
typedef struct { float x, y; } rgbcurve_node_t;
typedef struct
{
  rgbcurve_node_t curve_nodes[3][RGBCURVE_MAXNODES];
  int curve_num_nodes[3];
  int curve_type[3];
  int curve_autoscale;           // 0 RGB linked, 1 independent channels
  gboolean compensate_middle_grey;
  int preserve_colors;
} rgbcurve_params_t;

// Sets one channel's curve: {"cmd":"set_curve","module":"rgbcurve:0","channel":0,
// "nodes":[[x,y],...]}. Nodes are on the middle-grey-compensated scale
// (middle grey at 0.5, as darktable's "compensate middle gray"), which this
// switches on; channel 0 alone is the linked RGB curve.
static void _cmd_set_curve(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *m = _find_module(json_object_get_string_member_with_default(o, "module", ""));
  if(!m || g_strcmp0(m->op, "rgbcurve")) return _error("not an rgb curve");
  if(m->params_size != sizeof(rgbcurve_params_t)) return _error("unexpected rgb curve layout");
  rgbcurve_params_t *p = (rgbcurve_params_t *)m->params;
  const int ch = CLAMP((int)json_object_get_int_member_with_default(o, "channel", 0), 0, 2);
  JsonArray *nodes = json_object_has_member(o, "nodes") ? json_object_get_array_member(o, "nodes") : NULL;
  const int n = nodes ? MIN((int)json_array_get_length(nodes), RGBCURVE_MAXNODES) : 0;
  if(n < 2) return _error("a curve needs at least two points");
  // the nodes come in the compensated scale: convert any others on first use
  p->compensate_middle_grey = TRUE;
  for(int i = 0; i < n; i++)
  {
    JsonArray *pt = json_array_get_array_element(nodes, i);
    p->curve_nodes[ch][i].x = CLAMP((float)json_array_get_double_element(pt, 0), 0.0f, 1.0f);
    p->curve_nodes[ch][i].y = CLAMP((float)json_array_get_double_element(pt, 1), 0.0f, 1.0f);
  }
  p->curve_num_nodes[ch] = n;
  if(json_object_has_member(o, "linked"))
    p->curve_autoscale = json_object_get_boolean_member(o, "linked") ? 0 : 1;
  m->histogram_middle_grey = TRUE;
  _commit(m, TRUE);
  _ok_done(_ok());
}

// The curve's nodes and the histogram of its input, on the same scale:
// {"cmd":"curve","module":"rgbcurve:0"}. The histogram comes from the last
// render; asking turns its collection on (a render after this fills it).
static void _cmd_curve(JsonObject *o)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_iop_module_t *m = _find_module(json_object_get_string_member_with_default(o, "module", ""));
  if(!m || g_strcmp0(m->op, "rgbcurve")) return _error("not an rgb curve");
  if(m->params_size != sizeof(rgbcurve_params_t)) return _error("unexpected rgb curve layout");
  const rgbcurve_params_t *p = (const rgbcurve_params_t *)m->params;
  dt_dev_pixelpipe_iop_t *piece = _edit_piece(m);
  // collect the input histogram headless, on the compensated scale, from
  // the next render on (see _cmd_render); the module must run again for it
  if(H.histogram_module != m)
  {
    H.histogram_module = m;
    dt_dev_pixelpipe_cache_invalidate_later(&H.edit.pipe, m->iop_order, "curve histogram: ");
    H.edit.dirty = TRUE;
  }
  JsonBuilder *b = _ok();
  json_builder_set_member_name(b, "enabled");
  json_builder_add_boolean_value(b, m->enabled);
  json_builder_set_member_name(b, "compensated");
  json_builder_add_boolean_value(b, p->compensate_middle_grey);
  json_builder_set_member_name(b, "linked");
  json_builder_add_boolean_value(b, p->curve_autoscale == 0);
  json_builder_set_member_name(b, "nodes");
  json_builder_begin_array(b);
  for(int ch = 0; ch < 3; ch++)
  {
    json_builder_begin_array(b);
    for(int i = 0; i < CLAMP(p->curve_num_nodes[ch], 0, RGBCURVE_MAXNODES); i++)
    {
      json_builder_begin_array(b);
      json_builder_add_double_value(b, p->curve_nodes[ch][i].x);
      json_builder_add_double_value(b, p->curve_nodes[ch][i].y);
      json_builder_end_array(b);
    }
    json_builder_end_array(b);
  }
  json_builder_end_array(b);
  // histogram: bins of red, green and blue (4 values a bin in darktable's buffer)
  json_builder_set_member_name(b, "histogram");
  json_builder_begin_array(b);
  if(piece && piece->histogram && piece->histogram_stats.bins_count > 0)
    for(uint32_t i = 0; i < piece->histogram_stats.bins_count; i++)
      json_builder_add_int_value(b, (gint64)piece->histogram[4 * i] + piece->histogram[4 * i + 1] + piece->histogram[4 * i + 2]);
  json_builder_end_array(b);
  // and each channel's, for the red, green and blue curves
  json_builder_set_member_name(b, "channels");
  json_builder_begin_array(b);
  for(int c = 0; c < 3; c++)
  {
    json_builder_begin_array(b);
    if(piece && piece->histogram && piece->histogram_stats.bins_count > 0)
      for(uint32_t i = 0; i < piece->histogram_stats.bins_count; i++)
        json_builder_add_int_value(b, (gint64)piece->histogram[4 * i + c]);
    json_builder_end_array(b);
  }
  json_builder_end_array(b);
  _ok_done(b);
}

static void _cmd_save(void)
{
  if(!H.edit.loaded) return _error("no image open");
  dt_dev_write_history(&H.edit.dev);
  // "on import" means always: "after edit" skips the write when darktable's
  // own altered-history check (history hashes the GUI keeps) sees no change.
  // A save here is always deliberate.
  dt_conf_set_string("write_sidecar_files", "on import");
  const gboolean failed = dt_image_write_sidecar_file(H.imgid);
  dt_conf_set_string("write_sidecar_files", "never");
  if(failed) return _error("could not write the XMP sidecar");
  _ok_done(_ok());
}

// ------------------------------------------------------------------ main

int main(int argc, char *argv[])
{
  const char *frame = NULL, *config = NULL, *cache = NULL;
  // default tone mapper for unedited photos. darktable registers its
  // auto-applied presets at startup, so changing it means restarting
  const char *workflow = "scene-referred (sigmoid)";
  // anything after "--" goes straight to darktable (e.g. -- -d opencl -d perf)
  int extra = argc;
  for(int k = 1; k < argc; k++)
    if(!strcmp(argv[k], "--")) { extra = k + 1; break; }

  for(int k = 1; k < MIN(argc, extra) - 1; k++)
  {
    if(!strcmp(argv[k], "--frame")) frame = argv[++k];
    else if(!strcmp(argv[k], "--configdir")) config = argv[++k];
    else if(!strcmp(argv[k], "--cachedir")) cache = argv[++k];
    else if(!strcmp(argv[k], "--workflow")) workflow = argv[++k];
  }
  if(!frame || !config || !cache)
  {
    fprintf(stderr, "usage: darkroom-helper --frame FILE --configdir DIR --cachedir DIR"
                    " [--workflow 'scene-referred (filmic)']\n");
    return 2;
  }

  // keep the protocol channel private; everything else printed goes to stderr
  H.out = fdopen(dup(STDOUT_FILENO), "w");
  dup2(STDERR_FILENO, STDOUT_FILENO);

  H.frame_path = frame;
  H.frame_fd = open(frame, O_RDWR | O_CREAT, 0600);
  if(H.frame_fd < 0) { perror("frame file"); return 1; }

  gchar *workflow_conf = g_strdup_printf("plugins/darkroom/workflow=%s", workflow);
  char *base_argv[] = { "darkroom-helper",
                        "--library", ":memory:",
                        "--configdir", (char *)config,
                        "--cachedir", (char *)cache,
                        "--conf", workflow_conf,
                        // darktable ships with OpenCL off on macOS; on Apple
                        // Silicon it's 4-5x faster with heavy modules and matches
                        // the CPU output. Kernels compile once into the cachedir.
                        "--conf", "opencl=TRUE" };
  const int base = G_N_ELEMENTS(base_argv);
  char **dt_argv = g_new0(char *, base + MAX(argc - extra, 0) + 1);
  for(int k = 0; k < base; k++) dt_argv[k] = base_argv[k];
  for(int k = extra; k < argc; k++) dt_argv[base + k - extra] = argv[k];
  if(dt_init(base + MAX(argc - extra, 0), dt_argv, FALSE, TRUE, NULL))
  {
    fprintf(stderr, "darktable failed to initialise\n");
    return 1;
  }
  // sidecars only on Save: darktable would otherwise write one whenever the
  // library history changes (styles, exports). Set as a normal setting, not
  // with --conf, whose overrides win over the switch _cmd_save makes.
  dt_conf_set_string("write_sidecar_files", "never");
  // With sidecar writing off, darktable only reads a sidecar's title,
  // description and so on into its library if each field's "import" flag is
  // set, and a fresh config leaves them unset: the next sidecar write would
  // then drop them. Set the flag, keeping the field's other flags.
  for(GList *l = dt_metadata_get_list(); l; l = g_list_next(l))
  {
    const dt_metadata_t *md = l->data;
    if(md->internal) continue;
    gchar *setting = g_strdup_printf("plugins/lighttable/metadata/%s_flag", dt_metadata_get_tag_subkey(md->tagname));
    dt_conf_set_int(setting, dt_conf_get_int(setting) | DT_METADATA_FLAG_IMPORTED);
    g_free(setting);
  }

  JsonBuilder *ready = json_builder_new();
  json_builder_begin_object(ready);
  json_builder_set_member_name(ready, "event");
  json_builder_add_string_value(ready, "ready");
  json_builder_set_member_name(ready, "version");
  json_builder_add_string_value(ready, darktable_package_version);
  json_builder_end_object(ready);
  _reply(ready);

  JsonParser *parser = json_parser_new();
  char *line = NULL;
  size_t cap = 0;
  while(getline(&line, &cap, stdin) > 0)
  {
    if(!json_parser_load_from_data(parser, line, -1, NULL)
       || !JSON_NODE_HOLDS_OBJECT(json_parser_get_root(parser)))
    {
      _error("malformed request");
      continue;
    }
    JsonObject *o = json_node_get_object(json_parser_get_root(parser));
    const char *cmd = json_object_get_string_member_with_default(o, "cmd", "");

    if(!strcmp(cmd, "open")) _cmd_open(o);
    else if(!strcmp(cmd, "render")) _cmd_render(o);
    else if(!strcmp(cmd, "set")) _cmd_set(o);
    else if(!strcmp(cmd, "enable")) _cmd_enable(o);
    else if(!strcmp(cmd, "set_many")) _cmd_set_many(o);
    else if(!strcmp(cmd, "history_end")) _cmd_history_end(o);
    else if(!strcmp(cmd, "set_location")) _cmd_set_location(o);
    else if(!strcmp(cmd, "set_info")) _cmd_set_info(o);
    else if(!strcmp(cmd, "set_curve")) _cmd_set_curve(o);
    else if(!strcmp(cmd, "curve")) _cmd_curve(o);
    else if(!strcmp(cmd, "auto_exposure")) _cmd_auto_exposure(o);
    else if(!strcmp(cmd, "add_instance")) _cmd_add_instance(o);
    else if(!strcmp(cmd, "lens_cameras")) _cmd_lens_cameras(o);
    else if(!strcmp(cmd, "lens_lenses")) _cmd_lens_lenses(o);
    else if(!strcmp(cmd, "set_text")) _cmd_set_text(o);
    else if(!strcmp(cmd, "add_local")) _cmd_add_local(o);
    else if(!strcmp(cmd, "set_shape")) _cmd_set_shape(o);
    else if(!strcmp(cmd, "shape")) _cmd_shape(o);
    else if(!strcmp(cmd, "rename_instance")) _cmd_rename_instance(o);
    else if(!strcmp(cmd, "presets")) _cmd_presets();
    else if(!strcmp(cmd, "look")) _cmd_look(o);
    else if(!strcmp(cmd, "paste")) _cmd_paste(o);
    else if(!strcmp(cmd, "apply_preset")) _cmd_apply_preset(o);
    else if(!strcmp(cmd, "save_preset")) _cmd_save_preset(o);
    else if(!strcmp(cmd, "delete_preset")) _cmd_delete_preset(o);
    else if(!strcmp(cmd, "reset_all")) _cmd_reset_all();
    else if(!strcmp(cmd, "reset")) _cmd_reset(o);
    else if(!strcmp(cmd, "modules")) _cmd_modules();
    else if(!strcmp(cmd, "save")) _cmd_save();
    else if(!strcmp(cmd, "styles")) _cmd_styles();
    else if(!strcmp(cmd, "apply_style")) _cmd_apply_style(o);
    else if(!strcmp(cmd, "toneequal_fit")) _cmd_toneequal_fit();
    else if(!strcmp(cmd, "filmic_autotune")) _cmd_filmic_autotune();
    else if(!strcmp(cmd, "export")) _cmd_export(o);
    else if(!strcmp(cmd, "quit")) break;
    else _error("unknown command");
  }
  free(line);
  g_object_unref(parser);

  _close_image();
  dt_cleanup();
  return 0;
}
