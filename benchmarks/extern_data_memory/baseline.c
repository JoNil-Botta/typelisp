#ifdef _WIN32
int _fltused = 0;
#endif

long long tl_data_word = 7;
float tl_data_float = 42.75f;
unsigned char tl_data_byte[2] = {255, 91};
long long plain = 17;

long long tl_data_check(long long phase) {
    return tl_data_word == (phase ? 42 : 40)
        && tl_data_float == (phase ? 15.25f : 13.5f)
        && tl_data_byte[0] == (phase ? 253 : 254)
        && tl_data_byte[1] == 91
        && plain == (phase ? 21 : 19);
}
