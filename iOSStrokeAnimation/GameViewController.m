

#import "GameViewController.h"

@import Metal;
@import simd;
@import QuartzCore.CAMetalLayer;

// The max number of command buffers in flight
static const NSUInteger g_max_inflight_buffers = 3;

// Max API memory buffer size.
static const size_t MAX_BYTES_PER_FRAME = 1024*1024;

float lineVertexData1[6000];
float lineVertexData2[6000];
int lineMax1=0;
int lineMax2=0;

typedef struct
{
    matrix_float4x4 modelview_projection_matrix;
    matrix_float4x4 normal_matrix;
} uniforms_t;

@implementation GameViewController
{
    // layer
    CAMetalLayer *_metalLayer;
    id <CAMetalDrawable> _currentDrawable;
    BOOL _layerSizeDidUpdate;
    MTLRenderPassDescriptor *_renderPassDescriptor;
    
    // controller
    CADisplayLink *_timer;
    BOOL _gameLoopPaused;
    dispatch_semaphore_t _inflight_semaphore;
    id <MTLBuffer> _dynamicConstantBuffer;
    uint8_t _constantDataBufferIndex;
    
    // renderer
    id <MTLDevice> _device;
    id <MTLCommandQueue> _commandQueue;
    id <MTLLibrary> _defaultLibrary;
    id <MTLRenderPipelineState> _pipelineState;
    id <MTLBuffer> _vertexBuffer;
    id <MTLBuffer> _lineVertexBuffer1;
    id <MTLBuffer> _lineVertexBuffer2;
    id <MTLDepthStencilState> _depthState;
    id <MTLTexture> _depthTex;
    id <MTLTexture> _msaaTex;
    
    // uniforms
    matrix_float4x4 _projectionMatrix;
    matrix_float4x4 _viewMatrix;
    uniforms_t _uniform_buffer;
    float _rotation;
    int _cur1;
    int _cur2;
}

- (void)dealloc
{
    [_timer invalidate];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    _constantDataBufferIndex = 0;
    _inflight_semaphore = dispatch_semaphore_create(g_max_inflight_buffers);
    
    [self _setupMetal];
    [self _loadAssets];
    
    _timer = [CADisplayLink displayLinkWithTarget:self selector:@selector(_gameloop)];
    [_timer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)_setupMetal
{
    // Find a usable device
    _device = MTLCreateSystemDefaultDevice();
    
    // Create a new command queue
    _commandQueue = [_device newCommandQueue];
    
    // Load all the shader files with a metal file extension in the project
    _defaultLibrary = [_device newDefaultLibrary];
    
    // Setup metal layer and add as sub layer to view
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    
    // Change this to NO if the compute encoder is used as the last pass on the drawable texture
    _metalLayer.framebufferOnly = YES;
    
    // Add metal layer to the views layer hierarchy
    [_metalLayer setFrame:self.view.layer.frame];
    [self.view.layer addSublayer:_metalLayer];
    
    self.view.opaque = YES;
    self.view.backgroundColor = nil;
    self.view.contentScaleFactor = [UIScreen mainScreen].scale;
}

- (void)_loadAssets
{
    NSString* path = [[NSBundle mainBundle] pathForResource:@"lineData"
                                                     ofType:@"out"];
    NSString* content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    NSArray *arr1 = [content componentsSeparatedByString:@"\n"];
    for (int i=0; i<[arr1 count]; i++) {
        NSString* tempLine=arr1[i];
        NSArray *sepLine=[tempLine componentsSeparatedByString:@" "];
        lineVertexData1[i*3]=-[sepLine[0] floatValue]*16/696+8;
        lineVertexData1[i*3+1]=[sepLine[1] floatValue]*16/696-12;
        lineVertexData1[i*3+2]=0;
        lineMax1++;
    }
    
    path = [[NSBundle mainBundle] pathForResource:@"lineData2"
                                           ofType:@"out"];
    content = [NSString stringWithContentsOfFile:path
                                        encoding:NSUTF8StringEncoding
                                           error:NULL];
    NSArray *arr2 =[content componentsSeparatedByString:@"\n"];
    for (int i=0; i<[arr2 count]; i++) {
        NSString* tempLine=arr2[i];
        NSArray *sepLine=[tempLine componentsSeparatedByString:@" "];
        lineVertexData2[i*3]=-[sepLine[0] floatValue]*16/696+8;
        lineVertexData2[i*3+1]=[sepLine[1] floatValue]*16/696-12;
        lineVertexData2[i*3+2]=0;
        lineMax2++;
    }
    // Allocate one region of memory for the uniform buffer
    _dynamicConstantBuffer = [_device newBufferWithLength:MAX_BYTES_PER_FRAME options:0];
    _dynamicConstantBuffer.label = @"UniformBuffer";
    
    // Load the fragment program into the library
    id <MTLFunction> fragmentProgram = [_defaultLibrary newFunctionWithName:@"line_fragment"];
    
    // Load the vertex program into the library
    id <MTLFunction> vertexProgram = [_defaultLibrary newFunctionWithName:@"line_vertex"];
    
    
    _lineVertexBuffer1 = [_device newBufferWithBytes:lineVertexData1 length:sizeof(lineVertexData1) options:MTLResourceOptionCPUCacheModeDefault];
    _lineVertexBuffer1.label=@"Linevertices1";
    
    _lineVertexBuffer2 = [_device newBufferWithBytes:lineVertexData2 length:sizeof(lineVertexData2) options:MTLResourceOptionCPUCacheModeDefault];
    _lineVertexBuffer2.label=@"Linevertices2";
    
    // Create a reusable pipeline state
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.label = @"MyPipeline";
    [pipelineStateDescriptor setSampleCount: 1];
    [pipelineStateDescriptor setVertexFunction:vertexProgram];
    [pipelineStateDescriptor setFragmentFunction:fragmentProgram];
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipelineStateDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    
    NSError* error = NULL;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor error:&error];
    if (!_pipelineState) {
        NSLog(@"Failed to created pipeline state, error %@", error);
    }
    
    MTLDepthStencilDescriptor *depthStateDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthStateDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthStateDesc.depthWriteEnabled = YES;
    _depthState = [_device newDepthStencilStateWithDescriptor:depthStateDesc];
}

- (void)setupRenderPassDescriptorForTexture:(id <MTLTexture>) texture
{
    if (_renderPassDescriptor == nil)
        _renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    
    _renderPassDescriptor.colorAttachments[0].texture = texture;
    
    if (_cur1==0&&_cur2==0) {
        _renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
    }
    else{
        _renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    }
    _renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(1.0f, 1.0f, 1.0f, 1.0f);
    _renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    
    if (!_depthTex || (_depthTex && (_depthTex.width != texture.width || _depthTex.height != texture.height)))
    {
        //  If we need a depth texture and don't have one, or if the depth texture we have is the wrong size
        //  Then allocate one of the proper size
        
        MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat: MTLPixelFormatDepth32Float width: texture.width height: texture.height mipmapped: NO];
        _depthTex = [_device newTextureWithDescriptor: desc];
        _depthTex.label = @"Depth";
        
        _renderPassDescriptor.depthAttachment.texture = _depthTex;
        if (_cur1==0&&_cur2==0) {
            _renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
        }
        else{
            _renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        }
        _renderPassDescriptor.depthAttachment.clearDepth = 1.0f;
        _renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
    }
}

- (void)_render
{
    dispatch_semaphore_wait(_inflight_semaphore, DISPATCH_TIME_FOREVER);
    
    [self _update];
    
    // Create a new command buffer for each renderpass to the current drawable
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"MyCommand";
    
    // obtain a drawable texture for this render pass and set up the renderpass descriptor for the command encoder to render into
    id <CAMetalDrawable> drawable = [self currentDrawable];
    [self setupRenderPassDescriptorForTexture:drawable.texture];
    
    // Create a render command encoder so we can render into something
    id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:_renderPassDescriptor];
    renderEncoder.label = @"MyRenderEncoder";
    [renderEncoder setDepthStencilState:_depthState];
    
    // Set context state
    [renderEncoder pushDebugGroup:@"DrawFirstLine"];
    [renderEncoder setRenderPipelineState:_pipelineState];
    [renderEncoder setVertexBuffer:_lineVertexBuffer1 offset:0 atIndex:0 ];
    [renderEncoder setVertexBuffer:_dynamicConstantBuffer offset:(sizeof(uniforms_t) * _constantDataBufferIndex) atIndex:1 ];
    
    // Tell the render context we want to draw our primitives
    //[renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:36 instanceCount:1];
    [renderEncoder drawPrimitives:MTLPrimitiveTypeLineStrip vertexStart:0 vertexCount:_cur1];
    [renderEncoder popDebugGroup];
    
    [renderEncoder pushDebugGroup:@"DrawSecondLine"];
    [renderEncoder setRenderPipelineState:_pipelineState];
    [renderEncoder setVertexBuffer:_lineVertexBuffer2 offset:0 atIndex:0 ];
    [renderEncoder setVertexBuffer:_dynamicConstantBuffer offset:(sizeof(uniforms_t) * _constantDataBufferIndex) atIndex:1 ];
    
    // Tell the render context we want to draw our primitives
    //[renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:36 instanceCount:1];
    [renderEncoder drawPrimitives:MTLPrimitiveTypeLineStrip vertexStart:0 vertexCount:_cur2];
    [renderEncoder popDebugGroup];
    
    // We're done encoding commands
    [renderEncoder endEncoding];
    
    // Call the view's completion handler which is required by the view since it will signal its semaphore and set up the next buffer
    __block dispatch_semaphore_t block_sema = _inflight_semaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        dispatch_semaphore_signal(block_sema);
    }];
    
    // The renderview assumes it can now increment the buffer index and that the previous index won't be touched until we cycle back around to the same index
    _constantDataBufferIndex = (_constantDataBufferIndex + 1) % g_max_inflight_buffers;
    
    // Schedule a present once the framebuffer is complete
    [commandBuffer presentDrawable:drawable];
    
    // Finalize rendering here & push the command buffer to the GPU
    [commandBuffer commit];
}

- (void)_reshape
{
    // When reshape is called, update the view and projection matricies since this means the view orientation or size changed
    float aspect = fabsf(self.view.bounds.size.width / self.view.bounds.size.height);
    _projectionMatrix = matrix_from_perspective_fov_aspectLH(65.0f * (M_PI / 180.0f), aspect, 0.1f, 100.0f);
    
    _viewMatrix = matrix_identity_float4x4;
}

- (void)_update
{
    matrix_float4x4 base_model = matrix_multiply(matrix_from_translation(0.0f, 0.0f, 24.0f), matrix_from_rotation(_rotation, 0.0f, 0.0f, 1.0f));
    matrix_float4x4 base_mv = matrix_multiply(_viewMatrix, base_model);
    matrix_float4x4 modelViewMatrix = matrix_multiply(base_mv, matrix_from_rotation(_rotation, 0.0f, 0.0f, 1.0f));
    
    _uniform_buffer.normal_matrix = matrix_invert(matrix_transpose(modelViewMatrix));
    _uniform_buffer.modelview_projection_matrix = matrix_multiply(_projectionMatrix, modelViewMatrix);
    
    // Load constant buffer data into appropriate buffer at current index
    uint8_t *bufferPointer = (uint8_t *)[_dynamicConstantBuffer contents] + (sizeof(uniforms_t) * _constantDataBufferIndex);
    memcpy(bufferPointer, &_uniform_buffer, sizeof(uniforms_t));
    
    if (_cur1!=lineMax1) {
        if (_cur1>=lineMax1-3) {
            _cur1++;
        }
        else{
            _cur1+=4;
        }
    }
    else if (_cur2!=lineMax2){
        if (_cur2>=lineMax2-3) {
            _cur2++;
        }
        else{
            _cur2+=4;
        }
    }
    else{
        _cur1=0;
        _cur2=0;
    }
    //_rotation += 0.01f;
    _rotation=90.0f * (M_PI / 180.0f);
}

// The main game loop called by the CADisplayLine timer
- (void)_gameloop
{
    @autoreleasepool {
        if (_layerSizeDidUpdate)
        {
            CGFloat nativeScale = self.view.window.screen.nativeScale;
            CGSize drawableSize = self.view.bounds.size;
            drawableSize.width *= nativeScale;
            drawableSize.height *= nativeScale;
            _metalLayer.drawableSize = drawableSize;
            
            [self _reshape];
            _layerSizeDidUpdate = NO;
        }
        
        // draw
        [self _render];
        
        _currentDrawable = nil;
    }
}

// Called whenever view changes orientation or layout is changed
- (void)viewDidLayoutSubviews
{
    _layerSizeDidUpdate = YES;
    [_metalLayer setFrame:self.view.layer.frame];
}

#pragma mark Utilities

- (id <CAMetalDrawable>)currentDrawable
{
    while (_currentDrawable == nil)
    {
        _currentDrawable = [_metalLayer nextDrawable];
        if (!_currentDrawable)
        {
            NSLog(@"CurrentDrawable is nil");
        }
    }
    
    return _currentDrawable;
}

static matrix_float4x4 matrix_from_perspective_fov_aspectLH(const float fovY, const float aspect, const float nearZ, const float farZ)
{
    float yscale = 1.0f / tanf(fovY * 0.5f); // 1 / tan == cot
    float xscale = yscale / aspect;
    float q = farZ / (farZ - nearZ);
    
    matrix_float4x4 m = {
        .columns[0] = { xscale, 0.0f, 0.0f, 0.0f },
        .columns[1] = { 0.0f, yscale, 0.0f, 0.0f },
        .columns[2] = { 0.0f, 0.0f, q, 1.0f },
        .columns[3] = { 0.0f, 0.0f, q * -nearZ, 0.0f }
    };
    
    return m;
}

static matrix_float4x4 matrix_from_translation(float x, float y, float z)
{
    matrix_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = (vector_float4) { x, y, z, 1.0 };
    return m;
}

static matrix_float4x4 matrix_from_rotation(float radians, float x, float y, float z)
{
    vector_float3 v = vector_normalize(((vector_float3){x, y, z}));
    float cos = cosf(radians);
    float cosp = 1.0f - cos;
    float sin = sinf(radians);
    
    matrix_float4x4 m = {
        .columns[0] = {
            cos + cosp * v.x * v.x,
            cosp * v.x * v.y + v.z * sin,
            cosp * v.x * v.z - v.y * sin,
            0.0f,
        },
        
        .columns[1] = {
            cosp * v.x * v.y - v.z * sin,
            cos + cosp * v.y * v.y,
            cosp * v.y * v.z + v.x * sin,
            0.0f,
        },
        
        .columns[2] = {
            cosp * v.x * v.z + v.y * sin,
            cosp * v.y * v.z - v.x * sin,
            cos + cosp * v.z * v.z,
            0.0f,
        },
        
        .columns[3] = { 0.0f, 0.0f, 0.0f, 1.0f
        }
    };
    return m;
}

@end
