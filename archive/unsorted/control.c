#include <string.h>
#include <stdlib.h>
#include <stdio.h>


int get_sentence(int argc, char** argv);
int get_report(int argc, char** argv);

char* get_operations_str[] = {
    "sentence",
    "s",
    "report",
    "r"
};

int (* get_operations_func[]) (int, char**) = {
    &get_sentence,
    &get_sentence,
    &get_report,
    &get_report
};


int main(int argc, char *argv[])
{
    if(argc > 2) {
        if (*argv[1] == 'g' || !strcmp(argv[1], "get")) {
            for (int i=0; i<(sizeof(get_operations_str)/sizeof(char*)); i++) {
                if (!strcmp(argv[2], get_operations_str[i])) {
                    // transparent argv and argc for operation
                    get_operations_func[i](argc-2, argv+2);
                }
            }
        }
    }

    return 0;
}

/*
 * operations implementations
 */
int get_sentence(int argc, char** argv) {
    system("sentences -o -c");
    return 0;
}

int get_report(int argc, char** argv) {
    system("operations/report");
    return 0;
}
