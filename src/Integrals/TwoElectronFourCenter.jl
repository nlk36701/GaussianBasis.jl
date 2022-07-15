function sparseERI_2e4c(BS::BasisSet, cutoff = 1e-12)

    # Number of unique integral elements
    N = (BS.nbas^2 - BS.nbas) ÷ 2 + BS.nbas
    N = (N^2 - N) ÷ 2 + N

    # Pre allocate output
    out = zeros(N)
    indexes = Array{NTuple{4,Int16}}(undef, N)

    # Pre compute a list of angular momentum numbers (l) for each shell
    Nvals = num_basis.(BS.basis)
    Nmax = maximum(Nvals)

    # Offset list for each shell, used to map shell index to AO index
    ao_offset = [sum(Nvals[1:(i-1)]) - 1 for i = 1:BS.nshells]

    # Unique shell pairs with i < j
    num_ij = (BS.nshells^2 - BS.nshells) ÷ 2 + BS.nshells

    # Pre allocate array to save ij pairs
    ij_vals = Array{NTuple{2,Int32}}(undef, num_ij)

    # Pre allocate array to save σij, that is the screening parameter for Schwarz 
    σvals = zeros(Float64, num_ij)

    ### Loop thorugh i and j such that i ≤ j. Save each pair into ij_vals and compute √σij for integral screening
    lim = Int32(BS.nshells - 1)
    for i = UnitRange{Int32}(zero(Int32),lim)
        @inbounds begin
        Li2 = Nvals[i+1]^2
            for j = UnitRange{Int32}(i, lim)
                Lj2 = Nvals[j+1]^2
                buf = zeros(Cdouble, Li2*Lj2)
                idx = index2(i,j) + 1
                ij_vals[idx] = (i+1,j+1)
                ERI_2e4c!(buf, BS, i+1, i+1, j+1 ,j+1)
                σvals[idx] = √maximum(buf)
            end
        end
    end

    buf_arrays = [zeros(Cdouble, Nmax^4) for _ = 1:Threads.nthreads()]
    
    # i,j,k,l => Shell indexes starting at zero
    # I, J, K, L => AO indexes starting at one
    @sync for ij in eachindex(ij_vals)
        Threads.@spawn begin
        @inbounds begin
            buf = buf_arrays[Threads.threadid()]
            i,j = ij_vals[ij] 
            Li, Lj = Nvals[i], Nvals[j]
            Lij = Li*Lj
            ioff = ao_offset[i]
            joff = ao_offset[j]
            for kl in ij:num_ij
                σ = σvals[ij]*σvals[kl]
                if σ < cutoff
                    continue
                end
                k,l = ij_vals[kl] 
                Lk, Ll = Nvals[k], Nvals[l]
                Lijk = Lij*Lk
                koff = ao_offset[k]
                loff = ao_offset[l]

                # Compute ERI
                ERI_2e4c!(buf, BS, i, j, k ,l)

                ### This block aims to retrieve unique elements within buf and map them to AO indexes
                # is, js, ks, ls are indexes within the shell e.g. for a p shell is = (1, 2, 3)
                # bl, bkl, bjkl are used to map the (i,j,k,l) index into a one-dimensional index for buf
                # That is, get the correct integrals for the AO quartet.
                for ls = 1:Ll
                    L = loff + ls
                    bl = Lijk*(ls-1)
                    for ks = 1:Lk
                        K = koff + ks
                        L < K ? break : nothing

                        # L ≥ K
                        KL = (L * (L + 1)) >> 1 + K                            
                        bkl = Lij*(ks-1) + bl
                        for js = 1:Lj
                            J = joff + js
                            bjkl = Li*(js-1) + bkl
                            for is = 1:Li
                                I = ioff + is
                                J < I ? break : nothing

                                IJ = (J * (J + 1)) >> 1 + I

                                #KL < IJ ? continue : nothing # This restriction does not work... idk why 

                                idx = index2(IJ,KL) + 1
                                out[idx] = buf[is + bjkl]
                                indexes[idx] = (I, J, K, L)
                            end
                        end
                    end
                end
            end
        end #inbounds
        end #spawn
    end #sync
    mask = abs.(out) .> cutoff
    return indexes[mask], out[mask]
end

function ERI_2e4c(BS::BasisSet, i, j, k, l)
    out = zeros(num_basis(BS.basis[i]), num_basis(BS.basis[j]),
                num_basis(BS.basis[k]), num_basis(BS.basis[l]))
    ERI_2e4c!(out, BS, i, j, k, l)
end

function ERI_2e4c!(out, BS::BasisSet{LCint}, i, j, k, l)
    cint2e_sph!(out, [i,j,k,l], BS.lib)
end

function ERI_2e4c!(out, BS::BasisSet, i, j, k, l)
    generate_ERI_quartet!(out, BS, i, j, k, l)
end

function ERI_2e4c(BS::BasisSet)
    N = BS.nbas
    out = zeros(N, N, N, N)
    ERI_2e4c!(out, BS)
end

function ERI_2e4c!(out, BS::BasisSet)

    # Save a list containing the number of basis for each shell
    Nvals = num_basis.(BS.basis)
    Nmax = maximum(Nvals)

    # Get slice corresponding to the address in S where the compute chunk goes
    ranges = UnitRange{Int64}[]
    iaccum = 1
    for i = 1:BS.nshells
        push!(ranges, iaccum:(iaccum+ Nvals[i] -1))
        iaccum += Nvals[i]
    end

    # Find unique (i,j,k,l) combinations given permutational symmetry
    unique_idx = NTuple{4,Int16}[]
    N = Int16(BS.nshells - 1)
    ZERO = zero(Int16)
    for i = ZERO:N
        for j = i:N
            for k = ZERO:N
                for l = k:N
                    if index2(i,j) < index2(k,l)
                        continue
                    end
                    push!(unique_idx, (i,j,k,l))
                end
            end
        end
    end

    # Initialize array for results
    bufs = [zeros(Cdouble, Nmax^4) for _ = 1:Threads.nthreads()]
    @sync for (i,j,k,l) in unique_idx
        Threads.@spawn begin
            @inbounds begin
                # Shift indexes (C starts with 0, Julia 1)
                id, jd, kd, ld = i+1, j+1, k+1, l+1
                Ni, Nj, Nk, Nl = Nvals[id], Nvals[jd], Nvals[kd], Nvals[ld]

                buf = bufs[Threads.threadid()]
                # Compute ERI
                ERI_2e4c!(buf, BS, id, jd, kd, ld)

                # Move results to output array
                ri, rj, rk, rl = ranges[id], ranges[jd], ranges[kd], ranges[ld]
                out[ri, rj, rk, rl] .= reshape(buf[1:Ni*Nj*Nk*Nl], (Ni, Nj, Nk, Nl))

                if i != j && k != l && index2(i,j) != index2(k,l)
                    # i,j permutation
                    out[rj, ri, rk, rl] .= permutedims(out[ri, rj, rk, rl], (2,1,3,4))
                    # k,l permutation
                    out[ri, rj, rl, rk] .= permutedims(out[ri, rj, rk, rl], (1,2,4,3))

                    # i,j + k,l permutatiom
                    out[rj, ri, rl, rk] .= permutedims(out[ri, rj, rk, rl], (2,1,4,3))

                    # ij, kl permutation
                    out[rk, rl, ri, rj] .= permutedims(out[ri, rj, rk, rl], (3,4,1,2))
                    # ij, kl + k,l permutation
                    out[rl, rk, ri, rj] .= permutedims(out[ri, rj, rk, rl], (4,3,1,2))
                    # ij, kl + i,j permutation
                    out[rk, rl, rj, ri] .= permutedims(out[ri, rj, rk, rl], (3,4,2,1))
                    # ij, kl + i,j + k,l permutation
                    out[rl, rk, rj, ri] .= permutedims(out[ri, rj, rk, rl], (4,3,2,1))

                elseif k != l && index2(i,j) != index2(k,l)
                    # k,l permutation
                    out[ri, rj, rl, rk] .= permutedims(out[ri, rj, rk, rl], (1,2,4,3))
                    # ij, kl permutation
                    out[rk, rl, ri, rj] .= permutedims(out[ri, rj, rk, rl], (3,4,1,2))
                    # ij, kl + k,l permutation
                    out[rl, rk, ri, rj] .= permutedims(out[ri, rj, rk, rl], (4,3,1,2))

                elseif i != j && index2(i,j) != index2(k,l)
                    # i,j permutation
                    out[rj, ri, rk, rl] .= permutedims(out[ri, rj, rk, rl], (2,1,3,4))

                    # ij, kl permutation
                    out[rk, rl, ri, rj] .= permutedims(out[ri, rj, rk, rl], (3,4,1,2))
                    # ij, kl + i,j permutation
                    out[rk, rl, rj, ri] .= permutedims(out[ri, rj, rk, rl], (3,4,2,1))
        
                elseif i != j && k != l 
                    # i,j permutation
                    out[rj, ri, rk, rl] .= permutedims(out[ri, rj, rk, rl], (2,1,3,4))
                    # k,l permutation
                    out[ri, rj, rl, rk] .= permutedims(out[ri, rj, rk, rl], (1,2,4,3))

                    # i,j + k,l permutatiom
                    out[rj, ri, rl, rk] .= permutedims(out[ri, rj, rk, rl], (2,1,4,3))
                elseif index2(i,j) != index2(k,l) 
                    # ij, kl permutation
                    out[rk, rl, ri, rj] .= permutedims(out[ri, rj, rk, rl], (3,4,1,2))
                end
            end #inbounds
        end #spawn
    end #sync

    return out
end