typedef void *(*StringFunction)(void *);

void *tl_certified_string_echo(void *value) {
    return value;
}

StringFunction tl_certified_string_pointer(void) {
    return tl_certified_string_echo;
}
