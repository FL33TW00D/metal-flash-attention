//
//  Attention.metal
//  MetalFlashAttention
//
//  Created by Philip Turner on 6/26/23.
//

#include <metal_stdlib>
#include "metal_data_type"
#include "metal_simdgroup_event"
#include "metal_simdgroup_matrix_storage"
using namespace metal;

// MARK: - Function Constants

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused"

// Dimensions of each matrix.
constant uint R [[function_constant(0)]];
constant uint C [[function_constant(1)]];
constant uint H [[function_constant(2)]];
constant uint D [[function_constant(3)]];

// Whether each matrix is transposed.
constant bool Q_trans [[function_constant(10)]];
constant bool K_trans [[function_constant(11)]];
constant bool V_trans [[function_constant(12)]];
constant bool O_trans [[function_constant(13)]];
constant uint Q_leading_dim = Q_trans ? R : H * D;
constant uint K_leading_dim = K_trans ? H * D : C;
constant uint V_leading_dim = V_trans ? C : H * D;
constant uint O_leading_dim = O_trans ? R : H * D;

// Value of `rsqrt(float(D))`.
constant float alpha [[function_constant(20)]];

constant uint Q_data_type [[function_constant(30)]];

constant bool batched [[function_constant(100)]];
constant bool masked [[function_constant(50000)]]; // 101
constant bool block_sparse [[function_constant(102)]];
constant bool forward [[function_constant(103)]];
constant bool backward [[function_constant(104)]];
constant bool generate_block_mask [[function_constant(105)]];
constant bool grouped_query [[function_constant(106)]];

constant ushort R_simd [[function_constant(200)]];
constant ushort C_simd [[function_constant(201)]];
constant ushort D_simd = (D + 7) / 8 * 8;

// TODO: Try reversing the traversal order to improve work distribution during
// causal sparse attention.
constant ushort R_splits [[function_constant(210)]];
constant bool R_traverse_backward [[function_constant(213)]];
constant ushort R_group = R_simd * R_splits;

constant ushort R_bank_offset [[function_constant(220)]];
constant ushort C_bank_offset [[function_constant(221)]];
constant ushort D_bank_offset [[function_constant(222)]];
constant bool R_bank_offset_defined = is_function_constant_defined(R_bank_offset);
constant bool C_bank_offset_defined = is_function_constant_defined(C_bank_offset);
constant bool D_bank_offset_defined = is_function_constant_defined(D_bank_offset);

constant ushort R_block_dim = R_group + (R_bank_offset_defined ? R_bank_offset : 0);
constant ushort C_block_dim = C_simd + (C_bank_offset_defined ? C_bank_offset : 0);
constant ushort D_block_dim = D_simd + (D_bank_offset_defined ? D_bank_offset : 0);
constant ushort Q_block_leading_dim = (Q_trans ? R_block_dim : D_block_dim);
constant ushort K_block_leading_dim = (K_trans ? D_block_dim : C_block_dim);
constant ushort V_block_leading_dim = (V_trans ? C_block_dim : D_block_dim);
constant ushort O_block_leading_dim = (O_trans ? R_block_dim : D_block_dim);

constant bool fuse_async_loads [[function_constant(230)]];
constant ushort V_block_offset = (K_trans ? C_simd * D_block_dim : D_simd * C_block_dim);

#pragma clang diagnostic pop

// MARK: - Utilities

template <typename T>
METAL_FUNC device T* apply_batch_offset(device T *pointer, ulong offset) {
  if (batched) {
    return pointer + offset;
  } else {
    return pointer;
  }
}

template <typename T>
METAL_FUNC thread simdgroup_matrix_storage<T>* get_sram(thread simdgroup_matrix_storage<T> *sram, ushort sram_leading_dim, ushort2 matrix_origin) {
  return sram + (matrix_origin.y / 8) * (sram_leading_dim / 8) + (matrix_origin.x / 8);
}

template <typename A_data_type, typename B_data_type, typename C_data_type>
void gemm(ushort M, ushort N, ushort K, bool accumulate,
          ushort A_leading_dim, thread simdgroup_matrix_storage<A_data_type>* A,
          ushort B_leading_dim, thread simdgroup_matrix_storage<B_data_type>* B,
          ushort C_leading_dim, thread simdgroup_matrix_storage<C_data_type>* C)
{
#pragma clang loop unroll(full)
  for (ushort k = 0; k < K; k += 8) {
#pragma clang loop unroll(full)
    for (ushort m = 0; m < M; m += 8) {
      ushort2 a_origin(k, m);
#pragma clang loop unroll(full)
      for (ushort n = 0; n < N; n += 8) {
        ushort2 b_origin(n, k);
        auto a = get_sram(A, A_leading_dim, a_origin);
        auto b = get_sram(B, B_leading_dim, b_origin);
        
        ushort2 c_origin(n, m);
        auto c = get_sram(C, C_leading_dim, c_origin);
        c->multiply(*a, *b, accumulate);
      }
    }
  }
}

template <typename T>
void apply_mask(ushort r, uint j_next, ushort2 offset_in_simd,
                device T *mask_src,
                thread simdgroup_matrix_storage<T>* attention_matrix)
{
#define LOAD_MASK \
ushort2 origin(c, r); \
simdgroup_matrix_storage<T> mask; \
\
if (C % 2 == 0) { \
mask.load(mask_src, C, origin); \
} else { \
mask.load_first(mask_src, C, origin); \
origin.x += 1; \
mask.load_second(mask_src, C, origin); \
} \
\
auto s = get_sram(attention_matrix, C_simd, origin); \
if (generate_block_mask) { \
*(s->thread_elements()) = *(mask.thread_elements()); \
} else { \
*(s->thread_elements()) += *(mask.thread_elements()); \
} \

  ushort C_edge = (C % C_simd == 0) ? C_simd : (C % C_simd);
  ushort C_floor = C_edge / 8 * 8;
  short C_modulo = C_edge - C_floor;
  
  if (C % 8 == 0) {
#pragma clang loop unroll(full)
    for (ushort c = 0; c < C_floor; c += 8) {
      LOAD_MASK
    }
    
    if (C_edge > 0) {
      if (j_next <= C) {
#pragma clang loop unroll(full)
        for (ushort c = C_floor; c < C_simd; c += 8) {
          LOAD_MASK
        }
      }
    }
  } else if (j_next <= C) {
#pragma clang loop unroll(full)
    for (ushort c = 0; c < C_simd; c += 8) {
      LOAD_MASK
    }
  } else {
#pragma clang loop unroll(full)
    for (ushort c = 0; c < C_floor; c += 8) {
      LOAD_MASK
    }
    ushort2 origin(C_floor, r);
    simdgroup_matrix_storage<T> mask;
    
    if (C % 2 == 0) {
      if (short(offset_in_simd.x) <= short(C_modulo - 2)) {
        mask.load(mask_src, C, origin);
      }
    } else {
      if (short(offset_in_simd.x) <= short(C_modulo - 1)) {
        mask.load_first(mask_src, C, origin);
      }
      
      if (generate_block_mask) {
        if (short(offset_in_simd.x) <= short(C_modulo - 2)) {
          origin.x += 1;
        }
        mask.load_second(mask_src, C, origin);
      } else {
        origin.x += 1;
        if (short(offset_in_simd.x) <= short(C_modulo - 2)) {
          mask.load_second(mask_src, C, origin);
        }
      }
    }
    
    auto s = get_sram(attention_matrix, C_simd, origin);
    if (generate_block_mask) {
      *(s->thread_elements()) = *(mask.thread_elements());
    } else {
      *(s->thread_elements()) += *(mask.thread_elements());
    }
  }
}

// MARK: - Kernels

template <typename T>
void _generate_block_mask_impl(threadgroup T *threadgroup_block [[threadgroup(0)]],
                               device T *mask [[buffer(21), function_constant(masked)]],
                               device uchar *block_mask [[buffer(13), function_constant(block_sparse)]],
                               
                               uint3 gid [[threadgroup_position_in_grid]],
                               ushort sidx [[simdgroup_index_in_threadgroup]],
                               ushort lane_id [[thread_index_in_simdgroup]])
{
  // TODO: Allocate a very tiny threadgroup block for this kernel:
  // roundup(one slot per simd, 16B)
  auto results_block = (threadgroup ushort2*)threadgroup_block;
  uint i = gid.x * R_group + sidx * R_simd;
  if (R % R_group > 0) {
    if (i >= R) {
      results_block[sidx] = ushort2(1, 1);
      return;
    }
  }
  
  ushort2 offset_in_simd = simdgroup_matrix_storage<T>::offset(lane_id);
  ushort R_edge = (R % R_simd == 0) ? R_simd : (R % R_simd);
  ushort R_floor = R_edge / 8 * 8;
  ushort R_modulo = R_edge - R_floor;
  bool i_in_bounds = i + R_simd <= R;
  
  uint j_block = gid.y;
  uint j_next = j_block * C_simd + C_simd;
  simdgroup_matrix_storage<T> attention_matrix[128];
  
  uint2 mask_offset(j_block * C_simd, gid.x * R_group + sidx * R_simd);
  mask_offset += uint2(offset_in_simd);
  auto mask_src = simdgroup_matrix_storage<T>::apply_offset(mask, C, mask_offset);
  
  // Apply explicit mask.
#pragma clang loop unroll(full)
  for (ushort r = 0; r < R_floor; r += 8) {
    apply_mask(r, j_next, offset_in_simd, mask_src, attention_matrix);
  }
  
  if (R_edge > 0) {
    if (i_in_bounds) {
#pragma clang loop unroll(full)
      for (ushort r = R_floor; r < R_simd; r += 8) {
        apply_mask(r, j_next, offset_in_simd, mask_src, attention_matrix);
      }
    } else {
      if (offset_in_simd.y < R_modulo) {
        apply_mask(R_floor, j_next, offset_in_simd, mask_src, attention_matrix);
      }
      T placeholder = attention_matrix[0].thread_elements()[0][0];
      placeholder = simd_broadcast_first(placeholder);
      
      if (offset_in_simd.y >= R_modulo) {
        for (ushort c = 0; c < C_simd; c += 8) {
          ushort2 origin(c, R_floor);
          auto s = get_sram(attention_matrix, C_simd, origin);
          *s = simdgroup_matrix_storage<T>(placeholder);
        }
      }
      for (ushort r = R_floor + 8; r < R_simd; r += 8) {
        for (ushort c = 0; c < C_simd; c += 8) {
          ushort2 origin(c, r);
          auto s = get_sram(attention_matrix, C_simd, origin);
          *s = simdgroup_matrix_storage<T>(placeholder);
        }
      }
    }
  }
  
  // Apply edge mask.
  if ((C % C_simd > 0) && (j_next > C)) {
    ushort C_modulo = C % C_simd;
    ushort C_floor = C_modulo - (C_modulo % 8);
    ushort C_edge_thread = C_modulo - C_floor;
    ushort c = C_floor;
    T placeholder = attention_matrix[0].thread_elements()[0][0];
    placeholder = simd_broadcast_first(placeholder);
    
    if (offset_in_simd.x >= C_edge_thread) {
      for (ushort r = 0; r < R_simd; r += 8) {
        auto s = get_sram(attention_matrix, C_simd, ushort2(c, r));
        *s = simdgroup_matrix_storage<T>(placeholder);
      }
    }
    
#pragma clang loop unroll(full)
    for (c += 8; c < C_simd; c += 8) {
#pragma clang loop unroll(full)
      for (ushort r = 0; r < R_simd; r += 8) {
        auto s = get_sram(attention_matrix, C_simd, ushort2(c, r));
        *s = simdgroup_matrix_storage<T>(placeholder);
      }
    }
  }
  
  T minimum = 0;
  T maximum = -numeric_limits<T>::max();
#pragma clang loop unroll(full)
  for (ushort r = 0; r < R_simd; r += 8) {
#pragma clang loop unroll(full)
    for (ushort c = 0; c < C_simd; c += 8) {
      auto s = get_sram(attention_matrix, C_simd, ushort2(c, r));
      vec<T, 2> elements = s->thread_elements()[0];
      minimum = min3(elements[0], elements[1], minimum);
      maximum = max3(elements[0], elements[1], maximum);
    }
  }
  ushort all_zero = false;
  ushort all_masked = false;
  if (minimum == maximum) {
    if (minimum == 0) {
      all_zero = true;
    } else if (minimum == -numeric_limits<T>::max()) {
      all_masked = true;
    }
  }
  all_zero = simd_ballot(all_zero).all();
  all_masked = simd_ballot(all_masked).all();
  results_block[sidx] = ushort2(all_zero, all_masked);
  threadgroup_barrier(mem_flags::mem_threadgroup);
  
  if (sidx == 0) {
    all_zero = true;
    all_masked = true;
    if (lane_id < R_splits) {
      ushort2 result = results_block[lane_id];
      all_zero = result[0];
      all_masked = result[1];
    }
    all_zero = simd_ballot(all_zero).all();
    all_masked = simd_ballot(all_masked).all();
    
    ushort block_mask_element;
    if (all_masked) {
      block_mask_element = 0;
    } else if (all_zero) {
      block_mask_element = 1;
    } else {
      block_mask_element = 2;
    }
    uint block_mask_leading_dim = (C + C_simd - 1) / C_simd;
    block_mask[gid.x * block_mask_leading_dim + gid.y] = block_mask_element;
  }
}

template <typename T>
void _attention_impl(device T *Q [[buffer(0)]],
                     device T *K [[buffer(1)]],
                     device T *V [[buffer(2)]],
                     device T *O [[buffer(3)]],
                     
                     threadgroup T *threadgroup_block [[threadgroup(0)]],
                     constant uint4 *query_offsets [[buffer(11), function_constant(grouped_query)]],
                     device T *mask [[buffer(12), function_constant(masked)]],
                     device uchar *block_mask [[buffer(13), function_constant(block_sparse)]],
                     
                     uint3 gid [[threadgroup_position_in_grid]],
                     ushort sidx [[simdgroup_index_in_threadgroup]],
                     ushort lane_id [[thread_index_in_simdgroup]])
{
  uint i = gid.x * R_group + sidx * R_simd;
  if (R % R_group > 0) {
    if (i >= R) {
      return;
    }
  }
  
  ushort2 offset_in_simd = simdgroup_matrix_storage<T>::offset(lane_id);
  uint4 head_offsets = gid.y;
  if (grouped_query) {
    head_offsets = query_offsets[gid.y];
  }
  ushort R_edge = (R % R_simd == 0) ? R_simd : (R % R_simd);
  ushort R_floor = R_edge / 8 * 8;
  ushort R_modulo = R_edge - R_floor;
  bool i_in_bounds = i + R_simd <= R;
  
  simdgroup_matrix_storage<T> Q_sram[128];
  simdgroup_matrix_storage<float> O_sram[128];
  float l_sram[128];
  float m_sram[128];
  
  // Load Q block.
  if (sidx == 0) {
    uint2 Q_offset(0, i);
    ushort2 src_tile(D, min(uint(R_group), R - Q_offset.y));
    ushort2 dst_tile(D_simd, src_tile.y);
    
    auto Q_src = simdgroup_matrix_storage<T>::apply_offset(Q, Q_leading_dim, Q_offset, Q_trans);
    Q_src += head_offsets[0] * (Q_trans ? D * R : D);
    Q_src = apply_batch_offset(Q_src, gid.z * R * H * D);
    
    simdgroup_event event;
    event.async_copy(threadgroup_block, Q_block_leading_dim, dst_tile, Q_src, Q_leading_dim, src_tile, Q_trans);
    simdgroup_event::wait(1, &event);
  }
  
  // Initialize O, l, m.
#pragma clang loop unroll(full)
  for (ushort r = 0; r < R_simd; r += 8) {
#pragma clang loop unroll(full)
    for (ushort d = 0; d < D_simd; d += 8) {
      auto o = get_sram(O_sram, D_simd, ushort2(d, r));
      *o = simdgroup_matrix_storage<float>(0);
    }
    l_sram[r / 8] = numeric_limits<float>::denorm_min();
    m_sram[r / 8] = -numeric_limits<float>::max();
  }
  auto Q_offset = ushort2(0, sidx * R_simd) + offset_in_simd;
  auto Q_block = simdgroup_matrix_storage<T>::apply_offset(threadgroup_block, Q_block_leading_dim, Q_offset, Q_trans);
  
  threadgroup_barrier(mem_flags::mem_threadgroup);
#pragma clang loop unroll(full)
  for (ushort r = 0; r < R_simd; r += 8) {
#pragma clang loop unroll(full)
    for (ushort d = 0; d < D_simd; d += 8) {
      ushort2 origin(d, r);
      auto q = get_sram(Q_sram, D_simd, origin);
      q->load(Q_block, Q_block_leading_dim, origin, Q_trans);
    }
  }
  
  uint j_block_max = (C + C_simd - 1) / C_simd;
  for (uint j_block = 0; j_block < j_block_max; j_block += 1) {
    ushort flags = masked ? 2 : 1;
    if (block_sparse) {
      flags = block_mask[gid.x * j_block_max + j_block];
      if (flags == 0) {
        continue;
      }
    }
    
    // Load K block.
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (sidx == 0) {
      uint2 K_offset(j_block * C_simd, 0);
      ushort2 K_src_tile(min(uint(C_simd), C - K_offset.x), D);
      ushort2 K_dst_tile(K_src_tile.x, D);
      
      auto K_src = simdgroup_matrix_storage<T>::apply_offset(K, K_leading_dim, K_offset, K_trans);
      K_src += head_offsets[1] * (K_trans ? D : D * C);
      K_src = apply_batch_offset(K_src, gid.z * C * H * D);
      
      if (fuse_async_loads) {
        uint2 V_offset(0, j_block * C_simd);
        uint C_ceil = (C + 7) / 8 * 8;
        ushort2 V_src_tile(D, min(uint(C_simd), C - V_offset.y));
        ushort2 V_dst_tile(D, (C >= 2560) ? C_simd : min(uint(C_simd), C_ceil - V_offset.y));
        
        auto V_src = simdgroup_matrix_storage<T>::apply_offset(V, V_leading_dim, V_offset, V_trans);
        V_src += head_offsets[2] * (V_trans ? D * C : D);
        V_src = apply_batch_offset(V_src, gid.z * C * H * D);
        
        simdgroup_event events[2];
        events[0].async_copy(threadgroup_block, K_block_leading_dim, K_dst_tile, K_src, K_leading_dim, K_src_tile, K_trans);
        events[1].async_copy(threadgroup_block + V_block_offset, V_block_leading_dim, V_dst_tile, V_src, V_leading_dim, V_src_tile, V_trans);
        simdgroup_event::wait(2, events);
      } else {
        simdgroup_event event;
        event.async_copy(threadgroup_block, K_block_leading_dim, K_dst_tile, K_src, K_leading_dim, K_src_tile, K_trans);
        simdgroup_event::wait(1, &event);
      }
    }
    auto K_block = simdgroup_matrix_storage<T>::apply_offset(threadgroup_block, K_block_leading_dim, offset_in_simd, K_trans);
    
    // Multiply Q * K.
    threadgroup_barrier(mem_flags::mem_threadgroup);
    simdgroup_matrix_storage<T> attention_matrix[128];
#pragma clang loop unroll(full)
    for (ushort d = 0; d < D_simd; d += 8) {
      simdgroup_matrix_storage<T> K_sram[128];
      if ((D != D_simd) && (d + 8 == D_simd) && (offset_in_simd.y >= D % 8)) {
#pragma clang loop unroll(full)
        for (ushort c = 0; c < C_simd; c += 8) {
          auto k = get_sram(K_sram, C_simd, ushort2(c, 0));
          *k = simdgroup_matrix_storage<T>(0);
        }
      } else {
#pragma clang loop unroll(full)
        for (ushort c = 0; c < C_simd; c += 8) {
          auto k = get_sram(K_sram, C_simd, ushort2(c, 0));
          k->load(K_block, K_block_leading_dim, ushort2(c, d), K_trans);
        }
      }
      gemm(R_simd, C_simd, 8, d > 0,
           D_simd, Q_sram + d / 8,
           C_simd, K_sram,
           C_simd, attention_matrix);
    }
    
    // Apply explicit mask.
    uint j_next = j_block * C_simd + C_simd;
    if (masked && flags == 2) {
      uint2 mask_offset(j_block * C_simd, gid.x * R_group + sidx * R_simd);
      mask_offset += uint2(offset_in_simd);
      auto mask_src = simdgroup_matrix_storage<T>::apply_offset(mask, C, mask_offset);
      
#pragma clang loop unroll(full)
      for (ushort r = 0; r < R_floor; r += 8) {
        apply_mask(r, j_next, offset_in_simd, mask_src, attention_matrix);
      }
      
      if (R_edge > 0) {
        if (i_in_bounds) {
#pragma clang loop unroll(full)
          for (ushort r = R_floor; r < R_simd; r += 8) {
            apply_mask(r, j_next, offset_in_simd, mask_src, attention_matrix);
          }
        } else {
          if (offset_in_simd.y < R_modulo) {
            apply_mask(R_floor, j_next, offset_in_simd, mask_src, attention_matrix);
          }
        }
      }
    }
    
    // Apply edge mask.
    if ((C % C_simd > 0) && (j_next > C)) {
      ushort C_modulo = C % C_simd;
      ushort C_floor = C_modulo - (C_modulo % 8);
      ushort C_edge_thread = C_modulo - C_floor;
      ushort c = C_floor;
      
#pragma clang loop unroll(full)
      for (ushort index = 0; index < 2; index += 1) {
        if (offset_in_simd.x + index >= C_edge_thread) {
#pragma clang loop unroll(full)
          for (ushort r = 0; r < R_simd; r += 8) {
            auto s = get_sram(attention_matrix, C_simd, ushort2(c, r));
            (s->thread_elements()[0])[index] = -numeric_limits<T>::max();
          }
        }
      }
      
#pragma clang loop unroll(full)
      for (c += 8; c < C_simd; c += 8) {
#pragma clang loop unroll(full)
        for (ushort r = 0; r < R_simd; r += 8) {
          auto s = get_sram(attention_matrix, C_simd, ushort2(c, r));
          *(s->thread_elements()) = -numeric_limits<T>::max();
        }
      }
    }
    
    // Compute softmax.
#pragma clang loop unroll(full)
    for (ushort r = 0; r < R_simd; r += 8) {
      float2 _m;
#pragma clang loop unroll(full)
      for (ushort c = 0; c < C_simd; c += 8) {
        auto s = get_sram(attention_matrix, C_simd, ushort2(c, r));
        if (c == 0) {
          _m = float2(*(s->thread_elements()));
        } else {
          _m = max(_m, float2(*(s->thread_elements())));
        }
      }
      float m = max(_m[0], _m[1]);
      m = max(m, simd_shuffle_xor(m, 1));
      m = max(m, simd_shuffle_xor(m, 8));
      
      constexpr T threshold = -numeric_limits<T>::max() / 2;
      if (masked && !block_sparse && m <= threshold) {
        for (ushort c = 0; c < C_simd; c += 8) {
          auto s = get_sram(attention_matrix, C_simd, ushort2(c, r));
          *(s->thread_elements()) = vec<T, 2>(0);
        }
      } else {
        m *= alpha;
        m = max(m, m_sram[r / 8]);
        
        float correction = exp2(M_LOG2E_F * (m_sram[r / 8] - m));
        if (m > m_sram[r / 8]) {
#pragma clang loop unroll(full)
          for (ushort d = 0; d < D_simd; d += 8) {
            auto o = get_sram(O_sram, D_simd, ushort2(d, r));
            *(o->thread_elements()) *= correction;
          }
        }
        m_sram[r / 8] = m;
        float subtrahend = m * M_LOG2E_F;
        
        float2 _l = 0;
#pragma clang loop unroll(full)
        for (ushort c = 0; c < C_simd; c += 8) {
          auto s = get_sram(attention_matrix, C_simd, ushort2(c, r));
          float2 p = float2(*s->thread_elements());
          p = exp2(fma(p, alpha * M_LOG2E_F, -subtrahend));
          *(s->thread_elements()) = vec<T, 2>(p);
          _l += float2(*(s->thread_elements()));
        }
        float l = _l[0] + _l[1];
        l += simd_shuffle_xor(l, 1);
        l += simd_shuffle_xor(l, 8);
        l_sram[r / 8] = fma(l_sram[r / 8], correction, l);
      }
    }
    
    // Load V block.
    if (!fuse_async_loads) {
      threadgroup_barrier(mem_flags::mem_threadgroup);
      if (sidx == 0) {
        uint2 V_offset(0, j_block * C_simd);
        uint C_ceil = (C + 7) / 8 * 8;
        ushort2 src_tile(D, min(uint(C_simd), C - V_offset.y));
        ushort2 dst_tile(D, (C >= 2560) ? C_simd : min(uint(C_simd), C_ceil - V_offset.y));
        
        auto V_src = simdgroup_matrix_storage<T>::apply_offset(V, V_leading_dim, V_offset, V_trans);
        V_src += head_offsets[2] * (V_trans ? D * C : D);
        V_src = apply_batch_offset(V_src, gid.z * C * H * D);
        
        simdgroup_event event;
        event.async_copy(threadgroup_block, V_block_leading_dim, dst_tile, V_src, V_leading_dim, src_tile, V_trans);
        simdgroup_event::wait(1, &event);
      }
    }
    auto V_block = simdgroup_matrix_storage<T>::apply_offset(threadgroup_block, V_block_leading_dim, offset_in_simd, V_trans);
    
    // Multiply P * V.
    if (fuse_async_loads) {
      V_block += V_block_offset;
    } else {
      threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    ushort C_edge = (C % C_simd == 0) ? C_simd : (C % C_simd);
    ushort C_ceil = (C >= 2560) ? C_simd : (C_edge + 7) / 8 * 8;
#pragma clang loop unroll(full)
    for (ushort c = 0; c < C_ceil; c += 8) {
      simdgroup_matrix_storage<T> V_sram[128];
#pragma clang loop unroll(full)
      for (ushort d = 0; d < D_simd; d += 8) {
        auto v = get_sram(V_sram, 8, ushort2(d, 0));
        v->load(V_block, V_block_leading_dim, ushort2(d, c), V_trans);
      }
      gemm(R_simd, D_simd, 8, true,
           C_simd, attention_matrix + c / 8,
           D_simd, V_sram,
           D_simd, O_sram);
    }
    
    if ((C % C_simd > 0) && (j_next < C)) {
#pragma clang loop unroll(full)
      for (ushort c = C_ceil; c < C_simd; c += 8) {
        simdgroup_matrix_storage<T> V_sram[128];
#pragma clang loop unroll(full)
        for (ushort d = 0; d < D_simd; d += 8) {
          auto v = get_sram(V_sram, 8, ushort2(d, 0));
          v->load(V_block, V_block_leading_dim, ushort2(d, c), V_trans);
        }
        gemm(R_simd, D_simd, 8, true,
             C_simd, attention_matrix + c / 8,
             D_simd, V_sram,
             D_simd, O_sram);
      }
    }
  }
  
  // Write O block.
  threadgroup_barrier(mem_flags::mem_threadgroup);
  auto O_offset = ushort2(0, sidx * R_simd) + offset_in_simd;
  auto O_block = simdgroup_matrix_storage<T>::apply_offset(threadgroup_block, O_block_leading_dim, O_offset, O_trans);
  
#pragma clang loop unroll(full)
  for (ushort r = 0; r < R_simd; r += 8) {
    float l = 1 / l_sram[r / 8];
#pragma clang loop unroll(full)
    for (ushort d = 0; d < D_simd; d += 8) {
      ushort2 origin(d, r);
      auto o_elements = get_sram(O_sram, D_simd, origin)->thread_elements();
      simdgroup_matrix_storage<T> o(vec<T, 2>(*o_elements * l));
      o.store(O_block, O_block_leading_dim, origin, O_trans);
    }
  }
  
  threadgroup_barrier(mem_flags::mem_threadgroup);
  if (sidx == 0) {
    uint2 O_offset(0, gid.x * R_group);
    ushort2 tile(D, min(uint(R_group), R - O_offset.y));
    
    auto O_dst = simdgroup_matrix_storage<T>::apply_offset(O, O_leading_dim, O_offset, O_trans);
    O_dst += head_offsets[3] * (O_trans ? D * R : D);
    O_dst = apply_batch_offset(O_dst, gid.z * R * H * D);
    
    simdgroup_event event;
    event.async_copy(O_dst, O_leading_dim, tile, threadgroup_block, O_block_leading_dim, tile, O_trans);
  }
}

kernel void attention(device void *Q [[buffer(0)]],
                      device void *K [[buffer(1)]],
                      device void *V [[buffer(2)]],
                      device void *O [[buffer(3)]],
                      
                      threadgroup void *threadgroup_block [[threadgroup(0)]],
                      constant ulong4 *matrix_offsets [[buffer(10), function_constant(batched)]],
                      constant uint4 *query_offsets [[buffer(11), function_constant(grouped_query)]],
                      device void *mask [[buffer(12), function_constant(masked)]],
                      device uchar *block_mask [[buffer(13), function_constant(block_sparse)]],
                      
                      uint3 gid [[threadgroup_position_in_grid]],
                      ushort sidx [[simdgroup_index_in_threadgroup]],
                      ushort lane_id [[thread_index_in_simdgroup]])
{
  if (batched) {
    if (masked) {
      mask = ((device uchar*)mask) + matrix_offsets[gid.z][0];
    }
    if (block_sparse) {
      block_mask += matrix_offsets[gid.z][1];
    }
  }
  
  if (generate_block_mask) {
    if (Q_data_type == MTLDataTypeFloat) {
      _generate_block_mask_impl((threadgroup float*)threadgroup_block, (device float*)mask, block_mask, gid, sidx, lane_id);
    } else if (Q_data_type == MTLDataTypeHalf) {
      _generate_block_mask_impl((threadgroup half*)threadgroup_block, (device half*)mask, block_mask, gid, sidx, lane_id);
    }
  } else if (forward) {
    if (Q_data_type == MTLDataTypeFloat) {
      _attention_impl((device float*)Q, (device float*)K, (device float*)V, (device float*)O, (threadgroup float*)threadgroup_block, query_offsets, (device float*)mask, block_mask, gid, sidx, lane_id);
    } else if (Q_data_type == MTLDataTypeHalf) {
      _attention_impl((device half*)Q, (device half*)K, (device half*)V, (device half*)O, (threadgroup half*)threadgroup_block, query_offsets, (device half*)mask, block_mask, gid, sidx, lane_id);
    }
  }
}
