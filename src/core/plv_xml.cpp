// ParseXML's parser: pugixml behind the C interface of plv_xml.h.
//
// Built with PUGIXML_NO_XPATH, PUGIXML_NO_EXCEPTIONS and PUGIXML_NO_STL (see
// CMakeLists.txt), so nothing here may throw or use the standard library
// containers. The document lives in malloc'd memory and is built with
// placement new: operator new would be the one reason left to need the C++
// runtime's allocator, and with exceptions off it cannot report failure.

#include "plv_xml.h"
#include "pugixml.hpp"

#include <new>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#endif

struct plv_xml_doc {
    pugi::xml_document doc;
};

namespace {

const unsigned int kParseFlags = pugi::parse_default | pugi::parse_trim_pcdata;

// Files above this are refused before any memory is committed. A user
// interface description is a few hundred kilobytes at most.
const long kMaxFileBytes = 64L << 20;

pugi::xml_node node_of(plv_xml_node_t n)
{
    return pugi::xml_node(reinterpret_cast<pugi::xml_node_struct *>(const_cast<plv_xml_node_opaque *>(n)));
}

plv_xml_node_t handle_of(pugi::xml_node n)
{
    return reinterpret_cast<plv_xml_node_t>(n.internal_object());
}

pugi::xml_attribute attr_of(plv_xml_attr_t a)
{
    return pugi::xml_attribute(
        reinterpret_cast<pugi::xml_attribute_struct *>(const_cast<plv_xml_attr_opaque *>(a)));
}

plv_xml_attr_t handle_of(pugi::xml_attribute a)
{
    return reinterpret_cast<plv_xml_attr_t>(a.internal_object());
}

pugi::xml_node skip_to_element(pugi::xml_node n)
{
    while(n && n.type() != pugi::node_element) n = n.next_sibling();
    return n;
}

plv_xml_doc_t * new_doc()
{
    void * mem = malloc(sizeof(plv_xml_doc_t));
    if(!mem) return NULL;
    return new(mem) plv_xml_doc_t();
}

void report(const pugi::xml_parse_result & r, const char * buf, size_t len, char * msg, size_t cap)
{
    // Line and column count bytes of the UTF-8 buffer; the offset is what
    // pugixml reports, which is exact for UTF-8 input.
    size_t off = (r.offset >= 0 && (size_t)r.offset <= len) ? (size_t)r.offset : len;
    size_t line = 1, col = 1, i;
    for(i = 0; i < off; i++) {
        if(buf[i] == '\n') { line++; col = 1; }
        else col++;
    }
    snprintf(msg, cap, "%s at offset %ld (line %u, column %u)", r.description(),
             (long)r.offset, (unsigned)line, (unsigned)col);
}

plv_xml_doc_t * parse_buffer(const char * buf, size_t len, pugi::xml_encoding enc, char * msg,
                             size_t cap)
{
    plv_xml_doc_t * d = new_doc();
    if(!d) {
        snprintf(msg, cap, "out of memory for the XML document");
        return NULL;
    }
    pugi::xml_parse_result r = d->doc.load_buffer(buf, len, kParseFlags, enc);
    if(!r) {
        report(r, buf, len, msg, cap);
        plv_xml_free(d);
        return NULL;
    }
    if(!skip_to_element(d->doc.first_child())) {
        snprintf(msg, cap, "the document has no element");
        plv_xml_free(d);
        return NULL;
    }
    return d;
}

FILE * open_utf8(const char * path)
{
#if defined(_WIN32)
    // fopen takes the ANSI code page on Windows, so a path with any character
    // outside it would not open.
    wchar_t wide[1024];
    if(MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, (int)(sizeof(wide) / sizeof(wide[0]))) == 0)
        return NULL;
    return _wfopen(wide, L"rb");
#else
    return fopen(path, "rb");
#endif
}

void trimmed(const char * s, const char ** begin, size_t * len)
{
    size_t n = strlen(s);
    while(n && (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r')) { s++; n--; }
    while(n && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\n' || s[n - 1] == '\r')) n--;
    *begin = s;
    *len = n;
}

} // namespace

extern "C" {

plv_xml_doc_t * plv_xml_parse_text(const char * text, size_t len, char * msg, size_t msg_cap)
{
    return parse_buffer(text, len, pugi::encoding_utf8, msg, msg_cap);
}

plv_xml_doc_t * plv_xml_parse_file(const char * path_utf8, int * status, char * msg, size_t msg_cap)
{
    FILE * fp = open_utf8(path_utf8);
    long size;
    char * buf;
    plv_xml_doc_t * d;

    if(!fp) {
        *status = PLV_XML_NOT_FOUND;
        snprintf(msg, msg_cap, "cannot open '%s'", path_utf8);
        return NULL;
    }
    if(fseek(fp, 0, SEEK_END) != 0 || (size = ftell(fp)) < 0 || size > kMaxFileBytes
       || fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        *status = PLV_XML_BAD;
        snprintf(msg, msg_cap, "'%s' is unreadable or above 64 MB", path_utf8);
        return NULL;
    }
    buf = (char *)malloc((size_t)size + 1);
    if(!buf) {
        fclose(fp);
        *status = PLV_XML_BAD;
        snprintf(msg, msg_cap, "out of memory reading '%s'", path_utf8);
        return NULL;
    }
    if(fread(buf, 1, (size_t)size, fp) != (size_t)size) {
        fclose(fp);
        free(buf);
        *status = PLV_XML_BAD;
        snprintf(msg, msg_cap, "could not read '%s'", path_utf8);
        return NULL;
    }
    fclose(fp);
    buf[size] = 0;

    // pugixml copies the buffer, and ours stays intact for the line count
    // of an error message.
    d = parse_buffer(buf, (size_t)size, pugi::encoding_auto, msg, msg_cap);
    free(buf);
    *status = d ? PLV_XML_OK : PLV_XML_BAD;
    return d;
}

void plv_xml_free(plv_xml_doc_t * doc)
{
    if(!doc) return;
    doc->~plv_xml_doc();
    free(doc);
}

plv_xml_node_t plv_xml_root_first(const plv_xml_doc_t * doc)
{
    return doc ? handle_of(skip_to_element(doc->doc.first_child())) : NULL;
}

plv_xml_node_t plv_xml_first(plv_xml_node_t node)
{
    return node ? handle_of(skip_to_element(node_of(node).first_child())) : NULL;
}

plv_xml_node_t plv_xml_next(plv_xml_node_t node)
{
    return node ? handle_of(skip_to_element(node_of(node).next_sibling())) : NULL;
}

size_t plv_xml_count(plv_xml_node_t first)
{
    size_t n = 0;
    for(; first; first = plv_xml_next(first)) n++;
    return n;
}

const char * plv_xml_name(plv_xml_node_t node)
{
    return node ? node_of(node).name() : "";
}

plv_xml_attr_t plv_xml_attr_first(plv_xml_node_t node)
{
    return node ? handle_of(node_of(node).first_attribute()) : NULL;
}

plv_xml_attr_t plv_xml_attr_next(plv_xml_attr_t attr)
{
    return attr ? handle_of(attr_of(attr).next_attribute()) : NULL;
}

size_t plv_xml_attr_count(plv_xml_node_t node)
{
    size_t n = 0;
    plv_xml_attr_t a;
    for(a = plv_xml_attr_first(node); a; a = plv_xml_attr_next(a)) n++;
    return n;
}

const char * plv_xml_attr_name(plv_xml_attr_t attr)
{
    return attr ? attr_of(attr).name() : "";
}

const char * plv_xml_attr_value(plv_xml_attr_t attr)
{
    return attr ? attr_of(attr).value() : "";
}

size_t plv_xml_text(plv_xml_node_t node, const char ** single, char * dst, size_t dst_cap)
{
    pugi::xml_node c;
    size_t total = 0, frags = 0;
    const char * first = NULL;
    size_t first_len = 0;

    *single = NULL;
    if(!node) {
        *single = "";
        return 0;
    }
    // pugixml already trims PCDATA (parse_trim_pcdata) and drops the
    // whitespace-only runs between elements; CDATA is kept verbatim, so it
    // is trimmed here the same way.
    for(c = node_of(node).first_child(); c; c = c.next_sibling()) {
        const char * b;
        size_t n;
        if(c.type() != pugi::node_pcdata && c.type() != pugi::node_cdata) continue;
        trimmed(c.value(), &b, &n);
        if(n == 0) continue;
        if(frags == 0) { first = b; first_len = n; }
        total += (frags ? 1 : 0) + n;
        frags++;
    }
    if(frags <= 1) {
        *single = first ? first : "";
        return first_len;
    }
    if(dst && dst_cap > total) {
        size_t pos = 0;
        frags = 0;
        for(c = node_of(node).first_child(); c; c = c.next_sibling()) {
            const char * b;
            size_t n;
            if(c.type() != pugi::node_pcdata && c.type() != pugi::node_cdata) continue;
            trimmed(c.value(), &b, &n);
            if(n == 0) continue;
            if(frags++) dst[pos++] = ' ';
            memcpy(dst + pos, b, n);
            pos += n;
        }
        dst[pos] = 0;
    }
    return total;
}

} // extern "C"
