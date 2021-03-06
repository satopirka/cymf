# 
# Copyright (c) 2020 Minato Sato
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.
#

from collections import Counter
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import wget
import zipfile
import numpy as np
import pandas as pd
from scipy import sparse
from sklearn.model_selection import train_test_split
from tqdm import tqdm

from . import ImplicitFeedbackDataset


class MovieLens(ImplicitFeedbackDataset):
    def __init__(self, dir_name="ml-100k", min_rating: float = 4.0, under_sampling: Optional[int] = None):
        super().__init__(dir_name, min_rating)

        if dir_name not in ("ml-100k", "ml-1m"):
            raise ValueError("dir_name must be 'ml-100k' or 'ml-1m'.")

        if not self.dir_path.exists():
            if not self.dir_path.parent.joinpath(self.dir_path.name + ".zip").exists():
                print("movielens file does not exist, downloading ...")
                wget.download(
                    f"http://files.grouplens.org/datasets/movielens/{self.dir_path.name}.zip",
                    out=str(self.dir_path.parent.joinpath(self.dir_path.name + ".zip"))
                )
            
            with zipfile.ZipFile(self.dir_path.parent.joinpath(self.dir_path.name + ".zip")) as zf:
                zf.extractall(self.dir_path.parent)

        print("loading movielens...")
        rating_file: Path
        df_all: pd.DataFrame
        if self.dir_path.name == "ml-100k":
            rating_file = self.dir_path.joinpath("u.data")
            df_all = pd.read_csv(rating_file,
                                 sep="\t",
                                 names=("user", "item", "rating", "timestamp"))
        elif self.dir_path.name == "ml-1m":
            rating_file = self.dir_path.joinpath("ratings.dat")
            df_all = pd.read_csv(rating_file,
                                 sep="::",
                                 names=("user", "item", "rating", "timestamp"))

        df_all.item = self.reset_id(df_all.item)
        df_all.user = self.reset_id(df_all.user)

        self.num_user = len(set(df_all.user))
        self.num_item = len(set(df_all.item))

        df_all = df_all[df_all["rating"] >= self.min_rating]
        df_all["rating"] = 1.0

        self.df_train, self.df_test = train_test_split(df_all, test_size=0.1, random_state=12345)
        self.df_train, self.df_valid = train_test_split(self.df_train, test_size=0.1, random_state=12345)

        self.train = self.to_matrix(self.df_train)
        self.valid = self.to_matrix(self.df_valid)
        self.test = self.to_matrix(self.df_test)

        self.train_size = self.train.nnz
        self.valid_size = self.valid.nnz
        self.test_size = self.test.nnz

    def reset_id(self, column: pd.Series) -> pd.Series:
        x2index: Dict[int, int] = {}
        index2x: Dict[int, int] = {}
        for x in set(column):
            if x not in x2index:
                index: int = len(x2index)
                x2index[x] = index
                index2x[index] = x
        column = column.map(lambda x: x2index[x])
        return column
    
