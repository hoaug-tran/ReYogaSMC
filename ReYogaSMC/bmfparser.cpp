//  SPDX-License-Identifier: GPL-2.0-only
//
//  bmfparser.cpp
//  ReYogaSMC
//
//  Created by Zhen on 2020/5/24.
//  Copyright © 2020 Zhen. All rights reserved.
//

#include "bmfparser.hpp"
#include "common.h"
#include <uuid/uuid.h>

// Firmware BMF metadata is optional. Keep parser failures observable through the
// final WMI property without dumping every unsupported vendor construct at boot.
#define error(str)               \
    do {                         \
        OSSafeReleaseNULL(name); \
        parsed = false;          \
        return dict;             \
    } while (0)
#define errors(str)     \
    do {                \
        parsed = false; \
    } while (0)
#define warning(str) \
    do {             \
    } while (0)

OSString *MOF::parse_string(char *buf, uint32_t size) {
    uint16_t *buf2 = reinterpret_cast<uint16_t *>(buf);
    if (size % 2 != 0 || !contains(buf, size)) {
        errors("invalid size");
        return OSString::withCString("invalid size");
    }
    const uint32_t outputSize = (size / 2) * 3 + 1;
    char *out = reinterpret_cast<char *>(IOMalloc(outputSize));
    if (!out) {
        errors("malloc failed");
        return OSString::withCString("malloc failed");
    }
    bzero(out, outputSize);

    uint32_t i, j;
    for (i = 0, j = 0; i < size / 2; ++i) {
        if (buf2[i] == 0) {
            break;
        } else if (buf2[i] < 0x80) {
            out[j++] = buf2[i];
        } else if (buf2[i] < 0x800) {
            out[j++] = 0xC0 | (buf2[i] >> 6);
            out[j++] = 0x80 | (buf2[i] & 0x3F);
        } else if (buf2[i] >= 0xD800 && buf2[i] <= 0xDBFF && i + 1 < size / 2 && buf2[i + 1] >= 0xDC00 && buf2[i + 1] <= 0xDFFF) {
            uint32_t c = 0x10000 + ((buf2[i] - 0xD800) << 10) + (buf2[i + 1] - 0xDC00);
            ++i;
            out[j++] = 0xF0 | (c >> 18);
            out[j++] = 0x80 | ((c >> 12) & 0x3F);
            out[j++] = 0x80 | ((c >> 6) & 0x3F);
            out[j++] = 0x80 | (c & 0x3F);
        } else {
            out[j++] = 0xE0 | (buf2[i] >> 12);
            out[j++] = 0x80 | ((buf2[i] >> 6) & 0x3F);
            out[j++] = 0x80 | (buf2[i] & 0x3F);
        }
    }
    out[j] = 0;
    OSString *ret = OSString::withCString(out);
    IOFree(out, outputSize);
    return ret;
}

uint16_t MOF::parse_valuemap(uint16_t *buf, bool map, uint32_t i) {
    OSString *value;
    uint32_t len = 0;
    while (len < 0x99) {
        if (!contains(buf + len, sizeof(uint16_t))) {
            errors("valuemap truncated");
            return 0;
        }
        if (buf[len] == 0)
            break;
        len++;
    }
    if (len == 0x99) {
        errors("valuemap missing terminator");
        return 0;
    }
    value = parse_string((char *)buf, len * 2);
    if (map)
        valuemap->setObject(i, value);
    else
        vmap->setObject(value, valuemap->getObject(i));
    OSSafeReleaseNULL(value);
    return len + 1;
}

uint32_t MOF::parse_valuemap(int32_t *buf, bool map, uint32_t i) {
    OSString *value;
    if (!contains(buf, sizeof(int32_t))) {
        errors("valuemap truncated");
        return 0;
    }
    char res[12];
    snprintf(res, sizeof(res), "%d", buf[0]);
    value = OSString::withCString(res);
    if (map)
        valuemap->setObject(i, value);
    else
        vmap->setObject(value, valuemap->getObject(i));
    OSSafeReleaseNULL(value);
    return 1;
}

/*
 *    0                   1                   2                   3
 *    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |         Item  length          |          Item  type           |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |        Pattern  0x00          |     Name  length  (single)    |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |  Name  length  (array) / none |            Name               |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |                                                               |
 *   |                Value / Qualifiers / Parameter                 |
 *   |                                                               |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 */

OSDictionary *MOF::parse_method(uint32_t *buf, uint32_t verify) {
    ++indent;
    OSDictionary *dict = OSDictionary::withCapacity(5);
    if (!dict || !contains(buf, 20) || buf[0] < 20 || !contains(buf, buf[0])) {
        parsed = false;
        return dict;
    }
    uint8_t *type = (uint8_t *)buf + 4;
    OSDictionary *item;
    OSString *name = nullptr;
    // #ifdef DEBUG
    //     ReYogaProperty::setNumber(dict, "length", buf[0], 32);
    //     ReYogaProperty::setString(dict, "type", "method");
    // #endif

    switch (verify) {
    case 0:
        break;

    case MOF_OFFSET_BOOLEAN:
        if (type[0] == MOF_BOOLEAN)
            break;

    case MOF_OFFSET_OBJECT:
        //            if (type[0] == MOF_OBJECT) break;
        // TODO: verify "object:" of upper item
        break;

    case MOF_OFFSET_STRING:
        if (type[0] == MOF_STRING)
            break;

    case MOF_OFFSET_SINT32:
        if (type[0] == MOF_SINT32)
            break;

    default:
        error("(UNKNOWN) type mismatch");
        break;
    }

    switch (type[0]) {
    case MOF_BOOLEAN:
        //            ReYogaProperty::setString(dict, "type", "BOOLEAN");
        //            break;
        //
    case MOF_STRING:
        //            ReYogaProperty::setString(dict, "type", "STRING");
        //            break;
        //
    case MOF_SINT32:
        //            ReYogaProperty::setString(dict, "type", "SINT32");
        //            break;
        //
    case MOF_OBJECT:
        //            ReYogaProperty::setString(dict, "type", "OBJECT");
        //            break;
        //
    case MOF_UINT8:
        //            ReYogaProperty::setString(dict, "type", "UINT8");
        //            break;
        //
    case MOF_UINT32:
        //            ReYogaProperty::setString(dict, "type", "UINT32");
        //            break;
        //
    case MOF_UINT64:
        //            ReYogaProperty::setString(dict, "type", "UINT64");
        break;

    default:
        ReYogaProperty::setNumber(dict, "type", type[0], 8);
        error("unknown type");
        break;
    }

    switch (type[1]) {
    case 0:
        //            dict->setObject("map", kOSBooleanFalse);
        //            break;
        //
    case 0x20:
        //            dict->setObject("map", kOSBooleanTrue);
        break;

    default:
        ReYogaProperty::setNumber(dict, "map", type[1], 8);
        error("unknown map type");
        break;
    }

    if (buf[2] != 0)
        error("wrong method pattern");
    uint32_t nlen = buf[3];
    uint32_t clen = buf[4];
    uint32_t *nbuf = buf + (buf[4] != 0xFFFFFFFF && buf[4] > 0xFFFF ? 4 : 5);

    if (nlen == 0xFFFFFFFF) {
        // Variable map or objects
        name = parse_string((char *)nbuf, clen);
        nbuf = (uint32_t *)((char *)nbuf + clen);
        uint32_t count = nbuf[1];
        if (count > 0xff)
            error("count exceeded");
        OSDictionary *variables = OSDictionary::withCapacity(count + 3);
        nbuf += 2;
        for (uint32_t i = 0; i < count; i++) {
            item = parse_method(nbuf);
            variables->merge(item);
            item->release();
            nbuf = (uint32_t *)((char *)nbuf + nbuf[0]);
        }
        //      dict->flushCollection();
        dict->setObject(name, variables);
        variables->release();
    } else if (type[0] != MOF_OBJECT | type[1] != 0x20) {
        // Variables or Qualifiers
        name = parse_string((char *)nbuf, nlen);
        switch (verify) {
        case 0:
            break;

        case MOF_OFFSET_BOOLEAN:
            if (strcasecmp(name->getCStringNoCopy(), "Dynamic") == 0) {
                //                  dict->flushCollection();
                break;
            }

        case MOF_OFFSET_OBJECT:
            //                  dict->flushCollection();
            break;

        case MOF_OFFSET_STRING:
            if (name->isEqualTo("CIMTYPE")) {
                //                  dict->flushCollection();
                // TODO: verify "object:" of upper item
                break;
            }

        case MOF_OFFSET_SINT32:
            if (name->isEqualTo("ID")) {
                //                  dict->flushCollection();
                break;
            }

        default:
            dict->setObject("verified", kOSBooleanFalse);
            break;
        }

        nbuf = (uint32_t *)((char *)nbuf + nlen);

        if (clen == 0xFFFFFFFF)
            clen = buf[0] - 0x14 - nlen;
        else if (clen > 0xFFFF)
            clen = buf[0] - 0x10 - nlen;
        else {
            if (clen != buf[0] - 0x1c)
                error("content length calc error");
            clen -= nlen;
        }

        // ValueMap
        if (type[1] == 0x20) {
            if (nbuf[0] != clen)
                error("valuemap length mismatch");
            if (nbuf[1] != 1)
                error("valuemap pattern mismatch");
            if (nbuf[3] != clen - 0xc)
                error("valuemap content length mismatch");
            uint32_t count = nbuf[2];
            if (count > 0xff)
                error("count exceeded");
            nbuf += 4;
            if (!verify) {
                bool map;
                if (strcasecmp(name->getCStringNoCopy(), "ValueMap") == 0)
                    map = true;
                else if (strcasecmp(name->getCStringNoCopy(), "Values") == 0)
                    map = false;
                else
                    error("invalid valuemap");

                if (map) {
                    valuemap = OSArray::withCapacity(count);
                    vmap = OSDictionary::withCapacity(count);
                    ReYogaProperty::setString(dict, name, "Values");
                }
                for (uint32_t i = 0; i < count; i++) {
                    switch (type[0]) {
                    case MOF_STRING:
                        nbuf = (uint32_t *)((uint16_t *)nbuf + parse_valuemap((uint16_t *)nbuf, map, i));
                        break;
                    case MOF_SINT32:
                        nbuf += parse_valuemap((int32_t *)nbuf, map, i);
                        break;
                    default:
                        break;
                    }
                }
                if (!map) {
                    dict->setObject(name, vmap);
                    valuemap->release();
                    vmap->release();
                }
            }
        } else {
            switch (type[0]) {
            case MOF_BOOLEAN:
                //              if (!verify)
                //                  dict->flushCollection();

                if (clen != 4 && clen != 2) {
                    error("boolean length mismatch");
                }

                switch (clen == 4 ? nbuf[0] : nbuf[0] & 0xFFFF) {
                case 0:
                    dict->setObject(name, kOSBooleanFalse);
                    break;

                case 0xFFFF:
                    dict->setObject(name, kOSBooleanTrue);
                    break;

                default:
                    error("invalid boolean");
                    break;
                }
                break;

            case MOF_STRING:
                //              if (!verify)
                //                  dict->flushCollection();
                ReYogaProperty::setOwned(dict, name, parse_string((char *)nbuf, clen));
                break;

            case MOF_SINT32:
                //              if (!verify)
                //                  dict->flushCollection();
                if (clen != 4)
                    error("sint32 length mismatch");
                ReYogaProperty::setNumber(dict, name, nbuf[0], 32); // TODO: should be signed int here
                break;

            default:
                errors("unexpected value type");
                ReYogaProperty::setBytes(dict, name, nbuf, buf[0] - 0x10 - nlen);
                break;
            }
        }
    } else {
        // Method, or just a class with name?
        name = parse_string((char *)(buf + 5), nlen);
        nbuf = (uint32_t *)((char *)nbuf + nlen);
        if (nbuf[1] != 1)
            error("pattern mismatch");
        uint32_t count = nbuf[2];
        if (count > 0xff)
            error("count exceeded");

        nbuf += 4;

        //        dict->flushCollection();
        OSDictionary *parameters = OSDictionary::withCapacity(count);
        for (uint32_t i = 0; i < count; i++) {
            item = parse_class(nbuf);
            char pname[16];
            snprintf(pname, 16, "parameter %d", i + 1);
            parameters->setObject(pname, item);
            item->release();
            nbuf = (uint32_t *)((char *)nbuf + nbuf[0]);
        }
        dict->setObject(name, parameters);
        parameters->release();

        count = nbuf[1];
        if (count > 0xff)
            error("count exceeded");
        nbuf += 2;
        OSDictionary *quaifiers = OSDictionary::withCapacity(count);
        for (uint32_t i = 0; i < count; i++) {
            item = parse_method(nbuf);
            quaifiers->merge(item);
            item->release();
            nbuf = (uint32_t *)((char *)nbuf + nbuf[0]);
        }
        parameters->setObject("quaifiers", quaifiers);
        quaifiers->release();
    }
    OSSafeReleaseNULL(name);
    if (parsed)
        --indent;
    return dict;
}

/*
 *    0                   1                   2                   3
 *    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |         Class  length         |          Class  type          |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |       Qualifier  length       |         Total  length         |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |          Pattern  0/1         |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |      Qualifiers  length       |      Qualifiers  count        |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |                                                               |
 *   |                           Qualifiers                          |
 *   |                                                               |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |       Variables  length       |       Variables  count        |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |                                                               |
 *   |                           Variables                           |
 *   |                                                               |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |        Methods  length        |        Methods  count         |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |                                                               |
 *   |                            Methods                            |
 *   |                                                               |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 */

OSDictionary *MOF::parse_class(uint32_t *buf) {
    ++indent;
    OSDictionary *dict = OSDictionary::withCapacity(11);
    if (!dict || !contains(buf, 20) || buf[0] < 20 || !contains(buf, buf[0])) {
        parsed = false;
        return dict;
    }
    uint32_t type = buf[1];
    OSDictionary *item;
    OSString *name = nullptr;

    switch (type) {
    case 0:
        //            ReYogaProperty::setString(dict, "type", "class");
        //            break;

    case 0xFFFFFFFF:
        //            ReYogaProperty::setString(dict, "type", "parameter");
        break;

    default:
        error("Wrong class type");
        break;
    }

    // #ifdef DEBUG
    //     ReYogaProperty::setNumber(dict, "length", buf[0], 32);
    // #endif

    uint32_t count;
    if (type && buf[2] != 0)
        error("Wrong class pattern");
    if (buf[4] != 0 && buf[4] != 1)
        error("Wrong class type"); // 0:class 1:parameter

    // #ifndef DEBUG
    //     dict->flushCollection();
    // #endif

    buf += 5;
    if (!contains(buf, 8))
        error("class body truncated");
    if (!type) {
        if (indent != 1)
            warning("wrong class level");
        count = buf[1];
        if (count > 0xff)
            error("count exceeded");
        buf += 2;
        OSDictionary *qualifiers = OSDictionary::withCapacity(count + 3);
        for (uint32_t i = 0; i < count; i++) {
            item = parse_method(buf);
            qualifiers->merge(item);
            item->release();
            buf = (uint32_t *)((char *)buf + buf[0]);
        }
        if (!parsed) {
            qualifiers->release();
            return dict;
        }

        OSString *guid = OSDynamicCast(OSString, qualifiers->getObject("guid"));
        if (!guid)
            guid = OSDynamicCast(OSString, qualifiers->getObject("GUID"));

        if (guid) {
            dict->setObject("GUID", guid);
            char guid_string[37];
            uuid_t guid_t;
            switch (guid->getLength()) {
            case 36:
                if (!uuid_parse(guid->getCStringNoCopy(), guid_t)) {
                    uuid_unparse_lower(guid_t, guid_string);
                    OSDictionary *entry = OSDynamicCast(OSDictionary, mData->getObject(guid_string));
                    if (entry)
                        entry->setObject("MOF", dict);
                    else
                        IOLog("%d: GUID 36 not found %s\n", indent, guid_string);
                    ReYogaProperty::setString(dict, "WDG", guid_string);
                    break;
                }

            case 38:
                strncpy(guid_string, guid->getCStringNoCopy() + 1, 37);
                guid_string[36] = 0;
                if (!uuid_parse(guid_string, guid_t)) {
                    uuid_unparse_lower(guid_t, guid_string);
                    OSDictionary *entry = OSDynamicCast(OSDictionary, mData->getObject(guid_string));
                    if (entry)
                        entry->setObject("MOF", dict);
                    else
                        IOLog("%d: GUID 38 not found %s\n", indent, guid_string);
                    ReYogaProperty::setString(dict, "WDG", guid_string);
                    break;
                }

            default:
                IOLog("%d: Unknown GUID format %d %s\n", indent, guid->getLength(), guid->getCStringNoCopy());
                break;
            }
        }

        switch (qualifiers->getCount()) {
        case 0:
            break;

        case 1:
            if (qualifiers->getObject("abstract")) {
                dict->merge(qualifiers);
                break;
            }

        default:
            dict->setObject("qualifiers", qualifiers);
        }
        qualifiers->release();
    }

    count = buf[1];
    if (count > 0xff)
        error("count exceeded");
    buf += 2;

    OSDictionary *variables = OSDictionary::withCapacity(count);
    for (uint32_t i = 0; i < count; i++) {
        item = parse_method(buf);
        variables->merge(item);
        item->release();
        buf = (uint32_t *)((char *)buf + buf[0]);
    }

    OSObject *val;
    count = 4;
    char const *property[4];
    property[0] = "__CLASS";
    property[1] = "__NAMESPACE";
    property[2] = "__SUPERCLASS";
    property[3] = "__CLASSFLAGS";
    while (count--) {
        val = variables->getObject(property[count]);
        if (val) {
            dict->setObject(property[count], val);
            variables->removeObject(property[count]);
        }
    }
    if (variables->getCount() != 0) {
        if (variables->getCount() == 1 && type)
            dict->merge(variables);
        else
            dict->setObject("variables", variables);
    }
    variables->release();

    if (!parsed)
        return dict;

    count = buf[1];
    if (count > 0xff)
        error("count exceeded");
    buf += 2;
    OSDictionary *methods = OSDictionary::withCapacity(count);
    for (uint32_t i = 0; i < count; i++) {
        item = parse_method(buf);
        methods->merge(item);
        item->release();
        buf = (uint32_t *)((char *)buf + buf[0]);
    }
    if (methods->getCount() != 0)
        dict->setObject(type ? "parameters" : "methods", methods);
    methods->release();
    if (parsed)
        --indent;
    return dict;
}

/*
 *    0                   1                   2                   3
 *    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |         Pattern  FOMB         |          BMF  length          |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |         Pattern  0x1          |         Pattern  0x1          |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |        Classes  count         |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |                                                               |
 *   |                            Classes                            |
 *   |                                                               |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |         Pattern  BMOF         |         Pattern  QUAL         |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |         Pattern  FLAV         |         Pattern  OR11         |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |         Offsets  count        |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 *   |                               |                               |
 *   |         Offset  address       |          Offset  type         |
 *   |                               |                               |
 *   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 */
OSObject *MOF::parse_bmf() {
    if (!contains(buf, 20)) {
        parsed = false;
        return OSString::withCString("BMF header truncated");
    }
    uint32_t *nbuf = (uint32_t *)buf;

    if (nbuf[0] != 0x424D4F46)
        errors("header mismatch");
    if (nbuf[2] != 1 | nbuf[3] != 1)
        errors("pattern mismatch");

    if (!parsed)
        return OSString::withCString("parse error");

    uint32_t count = nbuf[4];
    if (count > 0xff) {
        parsed = false;
        return OSString::withCString("BMF count exceeded");
    }
    OSDictionary *dict = OSDictionary::withCapacity(5 + count);
    if (!dict) {
        parsed = false;
        return nullptr;
    }
    OSDictionary *item;
    OSString *name = nullptr;

    OSDictionary *entry = OSDynamicCast(OSDictionary, mData->getObject(BMF_DATA_WMI_BUFFER));
    if (entry)
        ReYogaProperty::setString(dict, "MOF", "Base");
    else
        IOLog("%d: MOF GUID not found %s\n", indent, BMF_DATA_WMI_BUFFER);
    ReYogaProperty::setString(dict, "WDG", BMF_DATA_WMI_BUFFER);

    // #ifdef DEBUG
    //     ReYogaProperty::setNumber(dict, "length", nbuf[1], 32);
    // #endif

    nbuf += 5;
    if (count > 0xff)
        error("count exceeded");
    for (uint32_t i = 0; i < count; i++) {
        if (!contains(nbuf, 20))
            error("class header truncated");
        item = parse_class(nbuf);
        if (!item)
            error("class allocation failed");
        if ((name = OSDynamicCast(OSString, item->getObject("__CLASS")))) {
            dict->setObject(name, item);
            name = nullptr;
        } else {
            char res[10];
            snprintf(res, 10, "class %d", i);
            dict->setObject(res, item);
            warning("no __CLASS attribute found");
        }
        item->release();
        nbuf = (uint32_t *)((char *)nbuf + nbuf[0]);
    }
    if (!parsed)
        return dict;

    if (!contains(nbuf, 20))
        error("footer truncated");
    if (nbuf[0] != 0x464F4D42 | nbuf[1] != 0x4C415551 | nbuf[2] != 0x56414C46 | nbuf[3] != 0x3131524F)
        error("footer mismatch");

    count = nbuf[4];
    nbuf += 5;
    if (count > 0x1ff)
        error("count exceeded");
    OSArray *offsets = OSArray::withCapacity(count);
    for (uint32_t i = 0; i < count; i++) {
        if (!contains(nbuf, 8) || nbuf[0] >= size) {
            errors("offset table truncated");
            break;
        }
        item = parse_method((uint32_t *)(buf + nbuf[0]), nbuf[1]);
        if (!item) {
            errors("method allocation failed");
            break;
        }
        if (item->getObject("verified")) {
            OSDictionary *offset = OSDictionary::withCapacity(3);
            ReYogaProperty::setNumber(offset, "address", nbuf[0], 32);
            switch (nbuf[1]) {
            case MOF_OFFSET_BOOLEAN:
                ReYogaProperty::setString(offset, "type", "BOOLEAN");
                break;

            case MOF_OFFSET_OBJECT:
                ReYogaProperty::setString(offset, "type", "OBJECT, tosubclass");
                break;

            case MOF_OFFSET_STRING:
                ReYogaProperty::setString(offset, "type", "STRING");
                break;

            case MOF_OFFSET_SINT32:
                ReYogaProperty::setString(offset, "type", "SINT32");
                break;

            default:
                ReYogaProperty::setString(offset, "type", "UNKNOWN");
                break;
            }
            offset->merge(item);
            offsets->setObject(offset);
            offset->release();
        }
        item->release();
        nbuf += 2;
    }
    if (offsets->getCount() != 0)
        dict->setObject("offsets", offsets);
    offsets->release();
    return dict;
}
