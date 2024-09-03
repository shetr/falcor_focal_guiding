import DensityNode;

ParameterBlock<DensityNodes> gNodesIn;
ParameterBlock<DensityNodes> gNodesOut;
RWByteAddressBuffer gNodesOutSize;

cbuffer CB
{
    uint gNodesInSize;
}

[shader("compute")]
[numthreads(1,1,1)]
void computeMain(uint3 threadId : SV_DispatchThreadID)
{
    uint index = threadId.x;

}
