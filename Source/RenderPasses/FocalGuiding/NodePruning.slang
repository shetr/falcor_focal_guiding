import DensityNode;

ParameterBlock<DensityNodes> gNodes;
RWByteAddressBuffer gGlobalAccumulator;
RWByteAddressBuffer gNodesSize;

[shader("compute")]
[numthreads(1,1,1)]
void computeMain(uint3 threadId : SV_DispatchThreadID)
{
    uint nodeIndex = threadId.x;

}
