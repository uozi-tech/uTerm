#include <assert.h>
#include <string.h>
#include SCANNER_SOURCE
int main(void) {
#ifdef PYTHON
    for (unsigned delimiter_count = 0; delimiter_count <= 255; ++delimiter_count) {
        Scanner *scanner = tree_sitter_python_external_scanner_create();
        for (unsigned i = 0; i < delimiter_count; ++i) {
            array_push(&scanner->delimiters, ((Delimiter){.flags = SingleQuote}));
        }
        for (unsigned i = 1; i < 1000; ++i) array_push(&scanner->indents, (uint16_t)i);
        char buffer[TREE_SITTER_SERIALIZATION_BUFFER_SIZE + 16];
        memset(buffer, 0x5a, sizeof buffer);
        unsigned size = tree_sitter_python_external_scanner_serialize(scanner, buffer);
        assert(size <= TREE_SITTER_SERIALIZATION_BUFFER_SIZE);
        for (unsigned i = TREE_SITTER_SERIALIZATION_BUFFER_SIZE; i < sizeof buffer; ++i) assert(buffer[i] == 0x5a);
        Scanner *restored = tree_sitter_python_external_scanner_create();
        tree_sitter_python_external_scanner_deserialize(restored, buffer, size);
        assert(restored->delimiters.size == delimiter_count);
        assert(restored->indents.size > 1);
        for (unsigned i = 0; i < restored->indents.size; ++i) assert(*array_get(&restored->indents, i) == i);
        tree_sitter_python_external_scanner_destroy(scanner);
        tree_sitter_python_external_scanner_destroy(restored);
    }
#else
    Scanner *scanner = tree_sitter_yaml_external_scanner_create();
    for (unsigned i = 1; i < 1000; ++i) {
        array_push(&scanner->ind_typ_stk, IND_ROT);
        array_push(&scanner->ind_len_stk, (int16_t)i);
    }
    char buffer[TREE_SITTER_SERIALIZATION_BUFFER_SIZE + 16];
    memset(buffer, 0x5a, sizeof buffer);
    unsigned size = tree_sitter_yaml_external_scanner_serialize(scanner, buffer);
    assert(size <= TREE_SITTER_SERIALIZATION_BUFFER_SIZE);
    for (unsigned i = TREE_SITTER_SERIALIZATION_BUFFER_SIZE; i < sizeof buffer; ++i) assert(buffer[i] == 0x5a);
    Scanner *restored = tree_sitter_yaml_external_scanner_create();
    tree_sitter_yaml_external_scanner_deserialize(restored, buffer, size);
    assert(restored->ind_len_stk.size > 1);
    assert(restored->ind_len_stk.size == restored->ind_typ_stk.size);
    for (unsigned i = 1; i < restored->ind_len_stk.size; ++i) assert(*array_get(&restored->ind_len_stk, i) == i);
    tree_sitter_yaml_external_scanner_destroy(scanner);
    tree_sitter_yaml_external_scanner_destroy(restored);
#endif
}
