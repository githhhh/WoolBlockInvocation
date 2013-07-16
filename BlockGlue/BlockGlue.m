//
//  BlockGlue.m
//  BlockGlue
//
//  Created by Joshua Caswell on 7/14/13.
//  Copyright (c) 2013 Josh Caswell. All rights reserved.
//

#import "BlockGlue.h"
#import "BlockSignature.h"

#import "WoolBlockHelper.h"

#include <ffi/ffi.h>

#if !__has_feature(objc_arc)
#define __bridge 
#define __bridge_transfer 
#endif // Exclude if compiled with ARC

ffi_type * libffi_type_for_objc_encoding(const char * str);

@interface BlockGlue ()

- (id)initWithBlockSignature:(BlockSignature *)sig;
- (void *)allocate:(size_t)size;

/* Construct a list of ffi_type * describing the method signature of this invocation. */
- (ffi_type **)buildFFIArgTypeList;

@end

@implementation BlockGlue
{
    BlockSignature * blockSignature;
    NSMutableArray * blocks;
    void ** return_values;
    void ** arguments;
    NSMutableArray * allocations;
    NSMutableArray * retainedArgs;
    NSMutableArray * retainedReturnValues;
}

+ (instancetype)blockGlueWithSignature:(BlockSignature *)sig
{
    return [[[self alloc] initWithBlockSignature:sig] autorelease];
}

- (id)init
{
    [NSException raise:NSInvalidArgumentException
                format:@"Use blockGlueWithSignature: to create a new instance"];
    return nil;
}

- (id)initWithBlockSignature:(BlockSignature *)sig
{
    self = [super init];
    if( !self ) return nil;
    
    blockSignature = [sig retain];
    blocks = [NSMutableArray new];
    allocations = [NSMutableArray new];
    
    return self;
}

@synthesize retainsArguments;

#if !__has_feature(objc_arc)
- (void)dealloc
{
    [retainedReturnValues release];
    [retainedArgs release];
    
    [blockSignature release];
    [blocks release];
    [allocations release];
    
    [super dealloc];
}
#endif // Exclude if compiled with ARC

- (void *)allocate:(size_t)size
{
    NSMutableData * dat = [NSMutableData dataWithLength:size];
    [allocations addObject:dat];
    
    return [dat mutableBytes];
}

- (BlockSignature *)blockSignature
{
    return blockSignature;
}

- (void)setRetainsArguments:(BOOL)shouldRetainArguments
{
    if( shouldRetainArguments && !retainedArgs ){
        retainedArgs = [NSMutableArray new];
    }
    
    retainsArguments = shouldRetainArguments;
}

- (void)setBlock:(id)block
{
    [blocks removeAllObjects];
    [blocks addObject:block];
}

- (void)addBlock:(id)block
{
    [blocks addObject:block];
}

- (id)blockAtIndex:(NSUInteger)idx
{
    return [[[blocks objectAtIndex:idx] retain] autorelease];
}

- (NSArray *)allBlocks
{
    return [[blocks copy] autorelease];
}

- (void)setArgument:(void *)arg atIndex:(NSInteger)idx
{
    NSAssert(idx != 0, @"Argument 0 is reserved for a pointer to the invoked Block");
    NSAssert(idx < [blockSignature numberOfArguments],
             @"Setting argument at index %ld out of range for number of arguments %ld", idx,
             [blockSignature numberOfArguments]);
    if( !arguments ){
        arguments = [self allocate:(sizeof(void *) * [blockSignature numberOfArguments])];
        arguments[0] = [self allocate:sizeof(id)];
    }
    
    free(arguments[idx]);
    
    size_t size = [blockSignature sizeOfArgumentAtIndex:idx];
    arguments[idx] = [self allocate:size];
    if( retainsArguments && [blockSignature argumentAtIndexIsObject:idx] ){
        id obj = (__bridge_transfer id)*(void **)arg;
        [retainedArgs addObject:obj];
    }
    memcpy(arguments[idx], arg, size);
}

- (void)getArgument:(void *)buffer atIndex:(NSInteger)idx
{
    memcpy(buffer, arguments[idx], [blockSignature sizeOfArgumentAtIndex:idx]);
}

- (void)getReturnValue:(void *)buffer
{
    NSAssert(return_values != NULL, @"No return value set for %@", self);
    NSAssert([blocks count] < 2,
             @"Cannot get single return value for %@; "
             "more than one value present", self);
    
    memcpy(buffer, return_values[0], [blockSignature returnSize]);
    return;
}

- (void * const *)returnValues
{
    return return_values;
}

- (void)invoke
{
    NSAssert([blocks count] > 0, @"Cannot invoke %@ without Block", self);
    NSUInteger num_args = [blockSignature numberOfArguments];
    ffi_type ** arg_types = [self buildFFIArgTypeList];
    ffi_type * ret_type = libffi_type_for_objc_encoding([blockSignature returnType]);
    NSUInteger ret_size = [blockSignature returnSize];
    return_values = [self allocate:sizeof(void *) * [blocks count]];
    BOOL doRetainReturnVals = [blockSignature returnTypeIsObject];
    if( doRetainReturnVals ){
        retainedReturnValues = [NSMutableArray new];
    }
    
    for( NSUInteger idx = 0; idx < [blocks count]; idx++ ){
        
        ffi_cif inv_cif;
        ffi_status prep_status = ffi_prep_cif(&inv_cif, FFI_DEFAULT_ABI,
                                              (unsigned int)num_args,
                                              ret_type, arg_types);
        NSAssert(prep_status == FFI_OK, @"ffi_prep_cif failed for", self);
        
        void * ret_val = NULL;
        if( ret_size > 0 ){
            ret_val = [self allocate:ret_size];
            NSAssert(ret_val != NULL,
                     @"%@ failed to allocate space for return value", self);
        }
        
        memcpy(arguments[0], (__bridge void *)[blocks objectAtIndex:idx], sizeof(id));
        ffi_call(&inv_cif, BlockIMP([blocks objectAtIndex:idx]),
                 ret_val, arguments);
        return_values[idx] = ret_val;
        
        if( doRetainReturnVals ){
            [retainedReturnValues addObject:(id)ret_val];
        }
    }
}

- (id)invocationBlock
{
    // Return a block which encapsulates the invocation of all the Blocks.
    // This really only makes sense for a Block signature with void return.
    return [^void (void * arg1, ...){
        [self setRetainsArguments:YES];
        va_list args;
        va_start(args, arg1);
        void * arg = arg1;
        NSUInteger idx = 1;
        while( idx < [blockSignature numberOfArguments] ){
            
            if( [blockSignature argumentAtIndexIsPointer:idx] ){
                    
                    [self setArgument:&arg atIndex:idx];
                
            } else {
                    
                    [self setArgument:arg atIndex:idx];
            }
            
            arg = va_arg(args, void *);
            idx += 1;
        }
        va_end(args);
        [self invoke];
    } copy];
}

/*
 * Construct a list of ffi_type * describing the method signature of this
 * invocation. Steps through each argument in turn and interprets the ObjC
 * type encoding.
 */
- (ffi_type **)buildFFIArgTypeList
{
    NSUInteger num_args = [blockSignature numberOfArguments];
    ffi_type ** arg_types = [self allocate:sizeof(ffi_type *) * num_args];
    for( NSUInteger idx = 0; idx < num_args; idx++ ){
        arg_types[idx] = libffi_type_for_objc_encoding([blockSignature argumentTypeAtIndex:idx]);
    }
    
    return arg_types;
}

@end

/* ffi_type structures for common Cocoa structs */

/* N.B.: ffi_type constructions must be created and added as possible return
 * values from libffi_type_for_objc_encoding below for any custom structs that
 * will be encountered by the invocation. If libffi_type_for_objc_encoding
 * fails to find a match, it will abort.
 */
#if CGFLOAT_IS_DOUBLE
#define CGFloatFFI &ffi_type_double
#else
#define CGFloatFFI &ffi_type_float
#endif

static ffi_type CGPointFFI = (ffi_type){ .size = 0,
    .alignment = 0,
    .type = FFI_TYPE_STRUCT,
    .elements = (ffi_type * [3]){CGFloatFFI,
        CGFloatFFI,
        NULL}};


static ffi_type CGSizeFFI = (ffi_type){ .size = 0,
    .alignment = 0,
    .type = FFI_TYPE_STRUCT,
    .elements = (ffi_type * [3]){CGFloatFFI,
        CGFloatFFI,
        NULL}};

static ffi_type CGRectFFI = (ffi_type){ .size = 0,
    .alignment = 0,
    .type = FFI_TYPE_STRUCT,
    .elements = (ffi_type * [3]){&CGPointFFI,
        &CGSizeFFI, NULL}};

/* Translate an ObjC encoding string into a pointer to the appropriate
 * libffi type; this covers the CoreGraphics structs defined above,
 * and, on OS X, the AppKit equivalents.
 */
ffi_type * libffi_type_for_objc_encoding(const char * str)
{
    /* Slightly modfied version of Mike Ash's code from
     * https://github.com/mikeash/MABlockClosure/blob/master/MABlockClosure.m
     * Copyright (c) 2010, Michael Ash
     * All rights reserved.
     * Distributed under a BSD license. See MA_LICENSE.txt for details.
     */
#define SINT(type) do { \
if(str[0] == @encode(type)[0]) \
{ \
if(sizeof(type) == 1) \
return &ffi_type_sint8; \
else if(sizeof(type) == 2) \
return &ffi_type_sint16; \
else if(sizeof(type) == 4) \
return &ffi_type_sint32; \
else if(sizeof(type) == 8) \
return &ffi_type_sint64; \
else \
{ \
NSLog(@"fatal: %s, unknown size for type %s", __func__, #type); \
abort(); \
} \
} \
} while(0)
    
#define UINT(type) do { \
if(str[0] == @encode(type)[0]) \
{ \
if(sizeof(type) == 1) \
return &ffi_type_uint8; \
else if(sizeof(type) == 2) \
return &ffi_type_uint16; \
else if(sizeof(type) == 4) \
return &ffi_type_uint32; \
else if(sizeof(type) == 8) \
return &ffi_type_uint64; \
else \
{ \
NSLog(@"fatal: %s, unknown size for type %s", __func__, #type); \
abort(); \
} \
} \
} while(0)
    
#define INT(type) do { \
SINT(type); \
UINT(unsigned type); \
} while(0)
    
#define COND(type, name) do { \
if(str[0] == @encode(type)[0]) \
return &ffi_type_ ## name; \
} while(0)
    
#define PTR(type) COND(type, pointer)
    
#define STRUCT(structType, retType) do { \
if(strncmp(str, @encode(structType), strlen(@encode(structType))) == 0) \
{ \
return retType; \
} \
} while(0)
    
    SINT(_Bool);
    SINT(signed char);
    UINT(unsigned char);
    INT(short);
    INT(int);
    INT(long);
    INT(long long);
    
    PTR(id);
    PTR(Class);
    //    PTR(Protocol);
    PTR(SEL);
    PTR(void *);
    PTR(char *);
    PTR(void (*)(void));
    
    COND(float, float);
    COND(double, double);
    
    COND(void, void);
    
    // Mike Ash's code dynamically allocates ffi_types representing the
    // structures rather than statically defining them.
    STRUCT(CGPoint, &CGPointFFI);
    STRUCT(CGSize, &CGSizeFFI);
    STRUCT(CGRect, &CGRectFFI);
    
#if !TARGET_OS_IPHONE
    STRUCT(NSPoint, &CGPointFFI);
    STRUCT(NSSize, &CGSizeFFI);
    STRUCT(NSRect, &CGRectFFI);
#endif
    
    // Add custom structs here using
    // STRUCT(StructName, &ffi_typeForStruct);
    
    NSLog(@"fatal: %s, unknown encode string %s", __func__, str);
    abort();
}

/* End code from Mike Ash */