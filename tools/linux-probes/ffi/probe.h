#include <stdint.h>
#include <stddef.h>
typedef struct {uint8_t *data;size_t length;int32_t status;} ResultBytes;
ResultBytes fastra_probe_copy(const uint8_t *,size_t,int32_t);
void fastra_probe_free(uint8_t *,size_t);
