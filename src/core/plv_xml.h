/**
 * @file plv_xml.h
 * XML parsing for ParseXML, a thin C interface over pugixml.
 *
 * pugixml is C++; this interface keeps the MEX and the rest of the core in C.
 * Nothing here depends on LVGL, because parsing needs no display: ParseXML
 * works before Init.
 *
 * Nodes and attributes are opaque pointers into the document. They stay valid
 * until plv_xml_free, and a NULL node or attribute ends an iteration.
 */
#ifndef PLV_XML_H
#define PLV_XML_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct plv_xml_doc plv_xml_doc_t;
typedef const struct plv_xml_node_opaque * plv_xml_node_t;
typedef const struct plv_xml_attr_opaque * plv_xml_attr_t;

/* Results of plv_xml_parse_file other than a document. */
#define PLV_XML_OK         0
#define PLV_XML_NOT_FOUND  1   /* the path does not name a readable file */
#define PLV_XML_BAD        2   /* read or parse error, message in msg */

/* Parses len bytes of UTF-8 text. On failure returns NULL and writes the
 * parser's description, the byte offset and the line and column into msg. */
plv_xml_doc_t * plv_xml_parse_text(const char * text, size_t len, char * msg, size_t msg_cap);

/* Reads and parses a file. The path is UTF-8. The encoding of the file comes
 * from its byte order mark or declaration, UTF-8 when it has neither. */
plv_xml_doc_t * plv_xml_parse_file(const char * path_utf8, int * status, char * msg, size_t msg_cap);

void plv_xml_free(plv_xml_doc_t * doc);

/* Element nodes only: comments, declarations and processing instructions are
 * never returned. Text is read through plv_xml_text. */
plv_xml_node_t plv_xml_root_first(const plv_xml_doc_t * doc);
plv_xml_node_t plv_xml_first(plv_xml_node_t node);
plv_xml_node_t plv_xml_next(plv_xml_node_t node);
size_t         plv_xml_count(plv_xml_node_t first);   /* first and its element siblings */
const char *   plv_xml_name(plv_xml_node_t node);

plv_xml_attr_t plv_xml_attr_first(plv_xml_node_t node);
plv_xml_attr_t plv_xml_attr_next(plv_xml_attr_t attr);
size_t         plv_xml_attr_count(plv_xml_node_t node);
const char *   plv_xml_attr_name(plv_xml_attr_t attr);
const char *   plv_xml_attr_value(plv_xml_attr_t attr);

/* The text and CDATA children of node, each trimmed, joined by one space.
 * When there is at most one fragment, *single points at it and the return
 * value is its length, so no copy is made. Otherwise *single is NULL, and the
 * joined text is written to dst when dst_cap is large enough; the return
 * value is the joined length either way. */
size_t plv_xml_text(plv_xml_node_t node, const char ** single, char * dst, size_t dst_cap);

#ifdef __cplusplus
}
#endif

#endif /* PLV_XML_H */
