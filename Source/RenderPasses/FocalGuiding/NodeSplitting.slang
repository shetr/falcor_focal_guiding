import DensityNode;

ParameterBlock<DensityNodes> gNodesIn;
ParameterBlock<DensityNodes> gNodesOut;
RWByteAddressBuffer gNodesOutSize;

cbuffer CB
{
    uint gNodesInSize;
    float gSplittingThreshold;
}

[shader("compute")]
[numthreads(1,1,1)]
void computeMain(uint3 threadId : SV_DispatchThreadID)
{
    uint nodeIndex = threadId.x;

    for (int childIndex = 0; childIndex < 8; childIndex++)
    {
        DensityChild child = gNodesIn.getChildNode(nodeIndex, childIndex);
        if (child.density > gSplittingThreshold)
        {
            uint newNodeIndex;
            gNodesOutSize.InterlockedAdd(0, 1, newNodeIndex);
            gNodesOut.setChildNodeIndex(nodeIndex, childIndex, newNodeIndex);
            for (int ch = 0; ch < 8; ch++)
            {
                gNodesOut.setChildNodeIndex(newNodeIndex, ch, 0);
                gNodesOut.setChildAccumulator(newNodeIndex, ch, 1.0);
                gNodesOut.setChildDensity(newNodeIndex, ch, 1.0 / 8.0);
            }
        }
    }
}
